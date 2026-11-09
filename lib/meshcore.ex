defmodule Meshcore do
  @moduledoc """
  Elixir client for [MeshCore](https://meshcore.io) companion radios.

  This is a port of the Python library
  [`meshcore_py`](https://github.com/fdlamotte/meshcore_py): same features, same
  function names, with an OTP/Elixir flavour. Connect over **serial**, **TCP** or
  **BLE**, run commands, and react to events.

  ## Quick start

      {:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")

      {:ok, contacts} =
        case Meshcore.Commands.get_contacts(mc) do
          {:ok, event} -> {:ok, event.payload}
          {:error, event} -> raise "failed: \#{inspect(event.payload)}"
        end

      contact = contacts |> Map.values() |> hd()
      {:ok, _sent} = Meshcore.Commands.send_msg(mc, contact, "Hello from Elixir!")

      Meshcore.disconnect(mc)

  ## Mapping from Python

  | Python                                   | Elixir                                              |
  | ---------------------------------------- | --------------------------------------------------- |
  | `await MeshCore.create_serial(port)`     | `Meshcore.create_serial(port)`                      |
  | `await mc.commands.send_msg(c, "hi")`    | `Meshcore.Commands.send_msg(mc, c, "hi")`           |
  | `result.type == EventType.ERROR`         | `{:error, %Meshcore.Event{}}`                       |
  | `mc.subscribe(EventType.ACK, cb, filt)`  | `Meshcore.subscribe(mc, :ack, attribute_filters: filt)` |
  | `await mc.wait_for_event(...)`           | `Meshcore.wait_for_event(mc, type, opts)`           |
  | `mc.contacts`, `mc.self_info`            | `Meshcore.contacts(mc)`, `Meshcore.self_info(mc)`   |
  | timeouts in **seconds**                  | timeouts in **milliseconds**                        |

  See the *Migrating from Python* guide for the complete list.

  ## Events

  Events arrive as messages: `{:meshcore, subscription_ref, %Meshcore.Event{}}`.

      {:ok, sub} = Meshcore.subscribe(mc, :contact_msg_recv)

      receive do
        {:meshcore, ref, %Meshcore.Event{payload: %{text: text}}} when ref == sub.ref ->
          IO.puts(text)
      end

  ## Supervision

  Put a connection in your own supervision tree with `child_spec/1`:

      children = [
        {Meshcore,
         name: MyApp.Radio,
         transport: {Meshcore.Transport.TCP, host: "192.168.1.100", port: 5000},
         auto_reconnect: true}
      ]

  and use the registered name as `mc` everywhere.
  """

  alias Meshcore.{Client, Event, Subscription}
  alias Meshcore.Commands.Contact
  alias Meshcore.Transport.{BLE, Serial, TCP}

  @type mc :: GenServer.server()

  @start_opts [
    :name,
    :transport,
    :connect,
    :auto_reconnect,
    :max_reconnect_attempts,
    :default_timeout,
    :log_level
  ]

  # ===========================================================================
  # Starting and stopping
  # ===========================================================================

  @doc """
  Starts a connection process, linked to the caller – the supervised variant of
  the `create_*` functions.

  Unlike `create_tcp/3` and friends it does not block on the device: with
  `connect: true` (default) it connects in the background, retrying according to
  `:auto_reconnect`. Use `connect/1` to wait for the handshake.

  Options:

    * `:transport` (required) – `{module, options}` implementing `Meshcore.Transport`
    * `:name` – register the process under this name
    * `:connect` – connect right after starting (default `true`)
    * `:auto_reconnect` – reconnect with exponential backoff (1s, 2s, 4s, 8s…)
      after the link is lost (default `false`)
    * `:max_reconnect_attempts` – default `3`
    * `:default_timeout` – command timeout in ms (default `15_000`)
    * `:debug` / `:only_error` – raise or lower the log level of this connection
      (equivalent to Python's flags)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Client.start_link(normalize_opts(opts))

  @doc """
  Child specification for supervision trees. Restarts only after abnormal
  exits (a `disconnect/1` is final).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Connects over TCP and performs the handshake.

  Returns `{:ok, mc}` or `{:error, reason}`. The connection process is started
  under `Meshcore.ConnectionSupervisor` and is **not** restarted when it
  crashes – use `child_spec/1` for that.

  Options: `:debug`, `:only_error`, `:default_timeout`, `:auto_reconnect`,
  `:max_reconnect_attempts` (see `start_link/1`), `:connect_timeout`.
  """
  @spec create_tcp(String.t() | :inet.ip_address(), :inet.port_number(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def create_tcp(host, port, opts \\ []) do
    transport_opts = [host: host, port: port] ++ Keyword.take(opts, [:connect_timeout])
    create({TCP, transport_opts}, opts)
  end

  @doc """
  Connects over a serial port and performs the handshake.

  Requires the optional `:circuits_uart` dependency. If the device does not
  answer, the connection is retried once with the DTR line inverted (some
  boards reset on DTR).

  Options: `:baudrate` (default `115200`), `:dtr` (`true`), `:rts` (`false`),
  `:cx_delay` (ms, `100`), plus the options of `create_tcp/3`.
  """
  @spec create_serial(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create_serial(port, opts \\ []) do
    dtr = Keyword.get(opts, :dtr, true)

    serial = fn dtr ->
      [port: port, dtr: dtr] ++ Keyword.take(opts, [:baudrate, :rts, :cx_delay])
    end

    case create({Serial, serial.(dtr)}, opts) do
      {:ok, _} = ok ->
        ok

      {:error, _first} ->
        require Logger
        Logger.info("No response from meshcore node, trying to invert dtr")
        create({Serial, serial.(not dtr)}, opts)
    end
  end

  @doc """
  Connects over BLE and performs the handshake.

  BLE needs a platform adapter (see `Meshcore.Transport.BLE.Adapter`), passed as
  `:adapter`. Options: `:adapter` (required), `:address` (BLE address or part of
  the advertised name; `nil` scans for a `MeshCore*` device), `:pin` (pair
  after connecting), `:adapter_opts`, plus the options of `create_tcp/3`.
  """
  @spec create_ble(keyword()) :: {:ok, pid()} | {:error, term()}
  def create_ble(opts) do
    create(
      {BLE, Keyword.take(opts, [:adapter, :address, :pin, :adapter_opts, :write_timeout])},
      opts
    )
  end

  defp create(transport, opts) do
    client_opts =
      opts
      |> Keyword.put(:transport, transport)
      |> Keyword.put(:connect, false)
      |> normalize_opts()

    spec = Supervisor.child_spec({Client, client_opts}, restart: :temporary)

    with {:ok, pid} <- DynamicSupervisor.start_child(Meshcore.ConnectionSupervisor, spec) do
      case Client.connect(pid) do
        {:ok, _self_info} ->
          {:ok, pid}

        {:error, reason} ->
          Client.disconnect(pid)
          {:error, reason}
      end
    end
  end

  defp normalize_opts(opts) do
    level =
      cond do
        opts[:debug] -> :debug
        opts[:only_error] -> :error
        true -> opts[:log_level]
      end

    opts |> Keyword.take(@start_opts) |> Keyword.put(:log_level, level)
  end

  @doc """
  Connects (when started with `connect: false`) and runs the app-start
  handshake. Returns `{:ok, self_info_event}` or `{:error, reason}`.
  """
  @spec connect(mc()) :: {:ok, Event.t()} | {:error, term()}
  def connect(mc), do: Client.connect(mc)

  @doc """
  Disconnects from the device and stops the connection process, emitting a
  `:disconnected` event (`reason: "manual_disconnect"`) first.
  """
  @spec disconnect(mc()) :: :ok
  def disconnect(mc), do: Client.disconnect(mc)

  @doc "Synchronously stops the connection process without emitting events."
  @spec stop(mc()) :: :ok
  def stop(mc), do: GenServer.stop(mc, :normal)

  # ===========================================================================
  # Events
  # ===========================================================================

  @doc """
  Subscribes a process to events.

  `type` is an event type (`t:Meshcore.Event.type/0`), a list of types, or `nil`
  / `:all` for everything. Matching events are sent to the subscriber as
  `{:meshcore, ref, %Meshcore.Event{}}`, `ref` being `subscription.ref`.

  Options:

    * `:attribute_filters` – map (or keyword list) of attributes the event must
      carry, e.g. `%{channel_idx: 1}` or `%{pubkey_prefix: "a1b2c3d4e5f6"}`
    * `:pid` – the subscriber (default: the calling process)

  Subscriptions end when the subscriber exits or on `unsubscribe/1`.
  """
  @spec subscribe(mc(), Event.type() | [Event.type()] | nil | :all, keyword()) ::
          {:ok, Subscription.t()}
  def subscribe(mc, type, opts \\ []) do
    filters = opts |> Keyword.get(:attribute_filters, %{}) |> Map.new()
    Client.subscribe(mc, type, filters, Keyword.get(opts, :pid, self()))
  end

  @doc "Cancels a subscription. Messages already in the mailbox stay there."
  @spec unsubscribe(Subscription.t()) :: :ok
  def unsubscribe(%Subscription{mc: mc} = subscription), do: Client.unsubscribe(mc, subscription)

  @doc """
  Waits for an event of `type` (or any of a list of types) matching
  `:attribute_filters`.

  Returns `{:ok, event}` or `{:error, :timeout}`.
  Options: `:attribute_filters`, `:timeout` (ms, default: the connection's
  default timeout).
  """
  @spec wait_for_event(mc(), Event.type() | [Event.type()], keyword()) ::
          {:ok, Event.t()} | {:error, :timeout | :disconnected}
  def wait_for_event(mc, type, opts \\ []) do
    filters = opts |> Keyword.get(:attribute_filters, %{}) |> Map.new()
    Client.wait_for_event(mc, type, filters, opts[:timeout])
  end

  # ===========================================================================
  # Mirrored device state
  # ===========================================================================

  @doc "The known contacts, `%{public_key_hex => contact}`."
  @spec contacts(mc()) :: %{String.t() => map()}
  def contacts(mc), do: Client.get(mc, :contacts)

  @doc "`true` when a push notification suggests the contact list is out of date."
  @spec contacts_dirty?(mc()) :: boolean()
  def contacts_dirty?(mc), do: Client.get(mc, :contacts_dirty)

  @doc "Whether contacts are refreshed automatically on adverts and path updates."
  @spec auto_update_contacts?(mc()) :: boolean()
  def auto_update_contacts?(mc), do: Client.get(mc, :auto_update_contacts)

  @doc "Enables or disables automatic contact refresh."
  @spec set_auto_update_contacts(mc(), boolean()) :: :ok
  def set_auto_update_contacts(mc, value), do: Client.put(mc, :auto_update_contacts, value)

  @doc "The device's `:self_info` payload (empty map before the handshake)."
  @spec self_info(mc()) :: map()
  def self_info(mc), do: Client.get(mc, :self_info)

  @doc "The last device time seen in a `:current_time` event (`0` if never)."
  @spec time(mc()) :: non_neg_integer()
  def time(mc), do: Client.get(mc, :time)

  @doc "Whether the transport is connected."
  @spec connected?(mc()) :: boolean()
  def connected?(mc), do: Client.get(mc, :connected)

  @doc "Default command timeout in milliseconds."
  @spec default_timeout(mc()) :: pos_integer()
  def default_timeout(mc), do: Client.get(mc, :default_timeout)

  @doc "Sets the default command timeout in milliseconds."
  @spec set_default_timeout(mc(), pos_integer()) :: :ok
  def set_default_timeout(mc, ms), do: Client.put(mc, :default_timeout, ms)

  @doc "Contacts advertised but not added (manual-add mode), `%{public_key_hex => contact}`."
  @spec pending_contacts(mc()) :: %{String.t() => map()}
  def pending_contacts(mc), do: Client.get(mc, :pending_contacts)

  @doc "Removes and returns a pending contact by full hex public key."
  @spec pop_pending_contact(mc(), String.t()) :: map() | nil
  def pop_pending_contact(mc, key), do: Client.call(mc, {:pop_pending_contact, key})

  @doc "Forgets all pending contacts."
  @spec flush_pending_contacts(mc()) :: :ok
  def flush_pending_contacts(mc), do: Client.put(mc, :pending_contacts, %{})

  @doc """
  Enables decryption of group-channel packets seen in the RX log. Needed to
  annotate `:channel_msg_recv` events with `:path`, `:snr`, `:rssi` and
  `:recv_time`.
  """
  @spec set_decrypt_channel_logs(mc(), boolean()) :: :ok
  def set_decrypt_channel_logs(mc, value), do: Client.put(mc, :decrypt_channels, value)

  @doc "Finds a contact by (case-insensitive) advertised name."
  @spec get_contact_by_name(mc(), String.t()) :: map() | nil
  def get_contact_by_name(mc, name), do: Client.call(mc, {:contact_by_name, name})

  @doc "Finds a contact by (case-insensitive, possibly partial) hex public key prefix."
  @spec get_contact_by_key_prefix(mc(), String.t()) :: map() | nil
  def get_contact_by_key_prefix(mc, prefix), do: Client.call(mc, {:contact_by_prefix, prefix})

  # ===========================================================================
  # Helpers
  # ===========================================================================

  @doc """
  Starts pulling queued messages whenever the device announces them
  (`:messages_waiting`), and once immediately. The messages show up as
  `:contact_msg_recv` / `:channel_msg_recv` events for subscribers.
  """
  @spec start_auto_message_fetching(mc()) :: :ok
  def start_auto_message_fetching(mc), do: Client.call(mc, {:set_auto_fetch, true})

  @doc "Stops automatic message fetching."
  @spec stop_auto_message_fetching(mc()) :: :ok
  def stop_auto_message_fetching(mc), do: Client.call(mc, {:set_auto_fetch, false})

  @doc """
  Loads the contact list if it is empty – or, with `follow` set, if it is
  marked dirty – and returns whether a refresh was requested.
  """
  @spec ensure_contacts(mc(), boolean()) :: boolean()
  def ensure_contacts(mc, follow \\ false) do
    if map_size(contacts(mc)) == 0 or (follow and contacts_dirty?(mc)) do
      Contact.get_contacts(mc, lastmod: Client.get(mc, :lastmod))
      true
    else
      false
    end
  end
end
