defmodule Meshcore.Commands.Messaging do
  @moduledoc """
  Sending and receiving messages, remote logins, path discovery, traces and
  flood scopes.
  """

  require Logger
  import Meshcore.Util
  import Meshcore.Commands.Base

  alias Meshcore.{Client, Event, Packets}
  alias Meshcore.Commands.Contact

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  @doc """
  Fetches the next queued message. The result is a `:contact_msg_recv`,
  `:channel_msg_recv` or `:channel_data_recv` event, or `:no_more_msgs`.

  Options: `:timeout`.
  """
  @spec get_msg(mc(), keyword()) :: result()
  def get_msg(mc, opts \\ []) do
    send_command(
      mc,
      <<0x0A>>,
      [:contact_msg_recv, :channel_msg_recv, :channel_data_recv, :error, :no_more_msgs],
      opts
    )
  end

  defp send_login_raw(mc, dst, pwd),
    do: send_command(mc, <<0x1A>> <> to_key(dst, 32) <> pwd, [:msg_sent, :error])

  @doc """
  Sends a login request and returns once it has been queued (`:msg_sent`).
  Prefer `send_login_sync/4`.
  """
  @spec send_login(mc(), Meshcore.Util.destination(), String.t()) :: result()
  def send_login(mc, dst, pwd) do
    Logger.warning("*** please consider using send_login_sync instead of send_login")
    send_login_raw(mc, dst, pwd)
  end

  @doc """
  Logs in to a remote node (repeater, room server) and waits for the
  `:login_success` event. Returns `{:error, event}` when the request could not
  be sent or no success arrived in time.

  Options: `:timeout`, `:min_timeout` (ms; default: derived from the device's
  suggestion).
  """
  @spec send_login_sync(mc(), Meshcore.Util.destination(), String.t(), keyword()) :: result()
  def send_login_sync(mc, dst, pwd, opts \\ []) do
    Client.with_lock(mc, fn ->
      send_command(mc, <<0x1A>> <> to_key(dst, 32) <> pwd, [:msg_sent, :error],
        then: then_spec([:login_success], opts)
      )
    end)
  end

  @doc "Logs out of a remote node."
  @spec send_logout(mc(), Meshcore.Util.destination()) :: result()
  def send_logout(mc, dst), do: send_ok(mc, <<0x1D>> <> to_key(dst, 32))

  @doc """
  Requests the status of a remote node and returns once queued.
  Prefer `Meshcore.Commands.Binary.req_status_sync/3`.
  """
  @spec send_statusreq(mc(), Meshcore.Util.destination()) :: result()
  def send_statusreq(mc, dst) do
    Logger.warning("*** please consider using req_status_sync instead of send_statusreq")
    send_command(mc, <<0x1B>> <> to_key(dst, 32), [:msg_sent, :error])
  end

  @doc """
  Sends a CLI command to a remote node as a text message.

  Options: `:timestamp`, `:dst_type` (`:chat | :repeater | :room | :sensor` or the
  numeric type; taken from a contact map when available, else a repeater is
  assumed).
  """
  @spec send_cmd(mc(), Meshcore.Util.destination(), String.t(), keyword()) :: result()
  def send_cmd(mc, dst, cmd, opts \\ []) do
    dst_bytes = to_key(dst)
    Logger.debug("Sending command to #{hex(dst_bytes)}: #{cmd}")
    timestamp = opts[:timestamp] || now()

    dst_type =
      case {opts[:dst_type], dst} do
        {nil, %{type: type}} ->
          type

        {nil, _} ->
          Logger.warning(
            "Can't determine destination type, please ensure contacts first or specify dst_type when calling `send_cmd`. Assuming it's a repeater."
          )

          Packets.adv_type(:repeater)

        {type, _} when is_atom(type) ->
          Packets.adv_type(type)

        {type, _} ->
          type
      end

    txt_type = if dst_type == Packets.adv_type(:chat), do: :cli_cmd, else: :cli_data

    data =
      <<Packets.command(:send_txt_msg), Packets.txt_type(txt_type), 0>> <>
        u(timestamp, 4) <> dst_bytes <> cmd

    send_command(mc, data, [:msg_sent, :error])
  end

  @doc """
  Sends a direct message. Returns `:msg_sent` with `expected_ack` (raw bytes)
  and `suggested_timeout` (ms); wait for the matching `:ack` event to confirm
  delivery (or use `send_msg_with_retry/4`).

  Options: `:timestamp` (Unix seconds, default now), `:attempt` (default `0`).
  """
  @spec send_msg(mc(), Meshcore.Util.destination(), String.t(), keyword()) :: result()
  def send_msg(mc, dst, msg, opts \\ []) do
    dst_bytes = to_key(dst)
    Logger.debug("Sending message to #{hex(dst_bytes)}: #{msg}")
    timestamp = opts[:timestamp] || now()
    attempt = Keyword.get(opts, :attempt, 0)

    data = <<0x02, 0x00, attempt>> <> u(timestamp, 4) <> dst_bytes <> msg
    send_command(mc, data, [:msg_sent, :error])
  end

  @doc """
  Sends a direct message and retries until it is acknowledged.

  After `:flood_after` unacknowledged attempts the stored path is reset so the
  message is flooded. Returns `{:ok, msg_sent_event}` of the acknowledged
  attempt or `{:error, :not_acknowledged}`.

  Options: `:timestamp`, `:max_attempts` (3), `:max_flood_attempts` (2),
  `:flood_after` (2), `:timeout` / `:min_timeout` (ms per attempt; default
  derived from the device's suggestion × 1.2).

  Must be called from a process that can receive messages (it subscribes to
  `:ack` events temporarily).
  """
  @spec send_msg_with_retry(mc(), Meshcore.Util.destination(), String.t(), keyword()) ::
          {:ok, Event.t()} | {:error, :not_acknowledged}
  def send_msg_with_retry(mc, dst, msg, opts \\ []) do
    dst_bytes =
      try do
        to_key(dst, 32)
      rescue
        ArgumentError -> to_key(dst, 6)
      end

    contact = contact_by_prefix(mc, hex(dst_bytes))

    dst_bytes =
      if contact && byte_size(dst_bytes) < 32, do: to_key(contact, 32), else: dst_bytes

    {:ok, sub} = Meshcore.subscribe(mc, :ack)

    ctx = %{
      mc: mc,
      dst: dst,
      msg: msg,
      ref: sub.ref,
      timestamp: opts[:timestamp] || now(),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      max_flood_attempts: Keyword.get(opts, :max_flood_attempts, 2),
      flood_after: Keyword.get(opts, :flood_after, 2),
      timeout: opts[:timeout],
      min_timeout: Keyword.get(opts, :min_timeout, 0)
    }

    try do
      retry_loop(ctx, %{
        dst_bytes: dst_bytes,
        contact: contact,
        attempts: 0,
        flood_attempts: 0,
        flood: false,
        sent: %{},
        acks: MapSet.new()
      })
    after
      Meshcore.unsubscribe(sub)
      flush_acks(sub.ref)
    end
  end

  defp retry_loop(ctx, st) do
    st = collect_acks(ctx.ref, st)

    cond do
      acked_event(st) ->
        {:ok, acked_event(st)}

      st.attempts >= ctx.max_attempts or
          (st.flood and st.flood_attempts >= ctx.max_flood_attempts) ->
        {:error, :not_acknowledged}

      true ->
        st = maybe_go_flood(ctx, st)

        if st.attempts > 0, do: Logger.info("Retry sending msg: #{st.attempts + 1}")

        case send_msg(ctx.mc, ctx.dst, ctx.msg, timestamp: ctx.timestamp, attempt: st.attempts) do
          {:error, event} ->
            Logger.error("Failed to send message: #{inspect(event.payload)}")
            retry_loop(ctx, bump(st))

          {:ok, event} ->
            flood = event.payload.type == 1
            code = hex(event.payload.expected_ack)
            st = %{st | flood: flood, sent: Map.put(st.sent, code, event)}
            st = await_ack(ctx, st, ack_timeout(ctx, event))
            retry_loop(ctx, bump(st))
        end
    end
  end

  defp bump(st) do
    st = %{st | attempts: st.attempts + 1}
    if st.flood, do: %{st | flood_attempts: st.flood_attempts + 1}, else: st
  end

  defp ack_timeout(%{timeout: t, min_timeout: min}, event) do
    t = if t in [nil, 0], do: trunc(event.payload.suggested_timeout * 1.2), else: t
    max(t, min)
  end

  defp maybe_go_flood(ctx, %{attempts: attempts, flood: false} = st)
       when attempts == ctx.flood_after do
    st =
      if byte_size(st.dst_bytes) < 32 do
        Logger.info("Don't have full key, retrieving contacts so we can reset path")
        Contact.get_contacts(ctx.mc)

        case contact_by_prefix(ctx.mc, hex(st.dst_bytes)) do
          nil -> st
          contact -> %{st | contact: contact, dst_bytes: to_key(contact, 32)}
        end
      else
        st
      end

    if byte_size(st.dst_bytes) < 32 do
      Logger.error("Couldn't reset path: full public key unknown, continuing ...")
      st
    else
      Logger.info("Resetting path")

      case Contact.reset_path(ctx.mc, st.dst_bytes) do
        {:error, event} ->
          Logger.error("Couldn't reset path #{inspect(event.payload)} continuing ...")
          st

        {:ok, _} ->
          %{st | flood: true}
      end
    end
  end

  defp maybe_go_flood(_ctx, st), do: st

  defp acked_event(st) do
    Enum.find_value(st.sent, fn {code, event} -> if MapSet.member?(st.acks, code), do: event end)
  end

  defp collect_acks(ref, st) do
    receive do
      {:meshcore, ^ref, %Event{type: :ack, attributes: %{code: code}}} ->
        collect_acks(ref, %{st | acks: MapSet.put(st.acks, code)})
    after
      0 -> st
    end
  end

  defp await_ack(ctx, st, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_ack(ctx, st, deadline)
  end

  defp do_await_ack(ctx, st, deadline) do
    st = collect_acks(ctx.ref, st)
    remaining = deadline - System.monotonic_time(:millisecond)

    if acked_event(st) || remaining <= 0 do
      st
    else
      receive do
        {:meshcore, ref, %Event{type: :ack, attributes: %{code: code}}} when ref == ctx.ref ->
          do_await_ack(ctx, %{st | acks: MapSet.put(st.acks, code)}, deadline)
      after
        remaining -> st
      end
    end
  end

  defp flush_acks(ref) do
    receive do
      {:meshcore, ^ref, _} -> flush_acks(ref)
    after
      0 -> :ok
    end
  end

  @doc """
  Sends a message to channel `chan`.

  Options: `:timestamp` – Unix seconds as an integer or a 4 byte little-endian
  binary (default now).
  """
  @spec send_chan_msg(mc(), 0..255, String.t(), keyword()) :: result()
  def send_chan_msg(mc, chan, msg, opts \\ []) do
    Logger.debug("Sending channel message to channel #{chan}: #{msg}")

    case timestamp_bytes(opts[:timestamp]) do
      {:ok, ts} -> send_ok(mc, <<0x03, 0x00, chan>> <> ts <> msg)
      :error -> {:error, Event.error(:invalid_timestamp_format)}
    end
  end

  defp timestamp_bytes(nil), do: {:ok, u(now(), 4)}
  defp timestamp_bytes(ts) when is_integer(ts), do: {:ok, u(ts, 4)}
  defp timestamp_bytes(<<_::binary-4>> = ts), do: {:ok, ts}
  defp timestamp_bytes(_), do: :error

  @doc """
  Requests telemetry from a remote node and returns once queued.
  Prefer `Meshcore.Commands.Binary.req_telemetry_sync/3`.
  """
  @spec send_telemetry_req(mc(), Meshcore.Util.destination()) :: result()
  def send_telemetry_req(mc, dst) do
    Logger.warning("*** please consider using req_telemetry_sync instead of send_telemetry_req")
    send_command(mc, <<0x27, 0, 0, 0>> <> to_key(dst, 32), [:msg_sent, :error])
  end

  @doc "Starts path discovery towards `dst`; returns once queued. Prefer `send_path_discovery_sync/3`."
  @spec send_path_discovery(mc(), Meshcore.Util.destination()) :: result()
  def send_path_discovery(mc, dst) do
    Logger.warning(
      "*** please consider using send_path_discovery_sync instead of send_path_discovery"
    )

    send_command(mc, <<0x34, 0>> <> to_key(dst, 32), [:msg_sent, :error])
  end

  @doc """
  Discovers the path to `dst` and waits for the `:path_response` event.
  Options: `:timeout`, `:min_timeout`.
  """
  @spec send_path_discovery_sync(mc(), Meshcore.Util.destination(), keyword()) :: result()
  def send_path_discovery_sync(mc, dst, opts \\ []) do
    Client.with_lock(mc, fn ->
      send_command(mc, <<0x34, 0>> <> to_key(dst, 32), [:msg_sent, :error],
        then: then_spec([:path_response], opts)
      )
    end)
  end

  @doc """
  Sends a trace packet through a chain of repeaters. The `:msg_sent` result
  carries the `tag`; the outcome arrives as a `:trace_data` event with the same
  `tag` attribute.

  Options:

    * `:auth_code` – 32 bit auth code (default `0`; `nil` = random)
    * `:tag` – 32 bit tag (default random)
    * `:flags` – the two low bits select the hash size (`1 <<< n` bytes)
    * `:path` – a string of comma separated hex hashes (`"23,5f,3a"`) or
      `{:raw, binary}` with the raw path bytes
  """
  @spec send_trace(mc(), keyword()) :: result()
  def send_trace(mc, opts \\ []) do
    tag = opts[:tag] || random_u32()
    auth = if Keyword.has_key?(opts, :auth_code), do: opts[:auth_code] || random_u32(), else: 0
    path = opts[:path]

    with {:ok, flags, hash_len} <- trace_flags(opts[:flags], path),
         {:ok, path_bytes} <- trace_path(path, hash_len) do
      data =
        <<Packets.command(:send_trace_path)>> <>
          u(tag, 4) <> u(auth, 4) <> <<flags>> <> path_bytes

      # firmware demands strictly more than 10 bytes
      data = if byte_size(data) <= 10, do: data <> <<0>>, else: data

      Logger.debug(
        "Sending trace: tag=#{tag}, auth=#{auth}, flags=#{flags}, path=#{hex(path_bytes)}"
      )

      send_command(mc, data, [:msg_sent, :error])
    else
      {:error, reason} -> {:error, Event.error(reason)}
    end
  end

  defp trace_flags(nil, path) when is_binary(path) do
    case path |> String.split(",") |> hd() |> byte_size() |> div(2) do
      1 ->
        {:ok, 0, 1}

      2 ->
        {:ok, 1, 2}

      4 ->
        {:ok, 2, 4}

      8 ->
        {:ok, 3, 8}

      n ->
        Logger.error("Invalid path format: unknown path_hash_len #{n}")
        {:error, :invalid_path_format}
    end
  end

  defp trace_flags(nil, _), do: {:ok, 0, 1}
  defp trace_flags(flags, _), do: {:ok, flags, Bitwise.bsl(1, Bitwise.band(flags, 3))}

  defp trace_path(nil, _), do: {:ok, <<>>}
  defp trace_path("", _), do: {:ok, <<>>}
  defp trace_path({:raw, bin}, _) when is_binary(bin), do: {:ok, bin}

  defp trace_path(path, hash_len) when is_binary(path) do
    path
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.take_while(&(&1 != ""))
    |> Enum.reduce_while({:ok, <<>>}, fn hex_val, {:ok, acc} ->
      with true <- byte_size(hex_val) == hash_len * 2,
           {:ok, bin} <- Base.decode16(hex_val, case: :mixed) do
        {:cont, {:ok, acc <> bin}}
      else
        _ ->
          Logger.error("Invalid path format: #{inspect(hex_val)}")
          {:halt, {:error, :invalid_path_format}}
      end
    end)
  end

  defp trace_path(other, _) do
    Logger.error("Unsupported path type: #{inspect(other)}")
    {:error, :unsupported_path_type}
  end

  @doc """
  Sends raw data via `CMD_SEND_RAW_DATA`. `payload` must be at least 4 bytes;
  `path` holds the intermediate hops (empty = zero-hop direct).
  """
  @spec send_raw_data(mc(), binary(), binary()) :: result()
  def send_raw_data(mc, payload, path \\ <<>>) when is_binary(payload) and is_binary(path) do
    if byte_size(payload) < 4, do: raise(ArgumentError, "payload must be at least 4 bytes")
    send_ok(mc, <<Packets.command(:send_raw_data), byte_size(path)>> <> path <> payload)
  end

  @doc """
  Sends a binary datagram to a channel (`CMD_SEND_CHANNEL_DATA`).

  `data_type` is `0x0001..0xFFFF` (`0xFFFF` is the developer namespace),
  `payload` at most 163 bytes. Options: `:path` (default `nil` = flood) and
  `:path_hash_mode` (default `0`).
  """
  @spec send_channel_data(mc(), 0..255, 1..0xFFFF, binary(), keyword()) :: result()
  def send_channel_data(mc, chan, data_type, payload, opts \\ []) do
    mode = Keyword.get(opts, :path_hash_mode, 0) || 0
    path = opts[:path]

    unless chan in 0..255, do: raise(ArgumentError, "chan must fit in one byte (0-255)")

    unless data_type in 1..0xFFFF,
      do: raise(ArgumentError, "data_type must be between 0x0001 and 0xFFFF")

    if byte_size(payload) > 163, do: raise(ArgumentError, "payload must be at most 163 bytes")

    path_bytes =
      case path do
        nil ->
          <<0xFF>>

        path when byte_size(path) >= 0xFF ->
          raise ArgumentError, "path must be shorter than 255 bytes"

        path ->
          <<Bitwise.bor(div(byte_size(path), mode + 1), Bitwise.bsl(mode, 6))>> <> path
      end

    data =
      <<Packets.command(:send_channel_data), chan>> <> path_bytes <> u(data_type, 2) <> payload

    send_ok(mc, data)
  end

  @doc """
  Sets the flood scope for outgoing flood packets.

    * `nil`, `""`, `"0"` or `"None"` – reset to the default scope
    * `"*"` – force unscoped
    * any other string – region name (a `#` is prepended if missing); the key is
      the first 16 bytes of its SHA-256
    * `{:key, binary}` – use a raw scope key

  Option `:force_unscoped` forces unscoped messages.
  """
  @spec set_flood_scope(mc(), nil | String.t() | {:key, binary()}, keyword()) :: result()
  def set_flood_scope(mc, scope, opts \\ []) do
    force = Keyword.get(opts, :force_unscoped, false)

    {key, force} =
      case scope do
        s when s in [nil, "", "0", "None"] -> {:binary.copy(<<0>>, 16), force}
        "*" -> {nil, true}
        {:key, key} when is_binary(key) -> {key, force}
        name when is_binary(name) -> {scope_key(name), force}
        other -> raise ArgumentError, "set_flood_scope: unsupported scope #{inspect(other)}"
      end

    data =
      if force,
        do: <<Packets.command(:set_flood_scope), 0x01>>,
        else: <<Packets.command(:set_flood_scope), 0x00>> <> key

    send_ok(mc, data)
  end

  defp scope_key(name) do
    name = if String.starts_with?(name, "#"), do: name, else: "#" <> name
    binary_part(sha256(name), 0, 16)
  end

  @doc "Resets the flood scope (sends an empty scope key)."
  @spec reset_flood_scope(mc()) :: result()
  def reset_flood_scope(mc), do: set_flood_scope(mc, {:key, <<>>})

  @doc "Forces unscoped flood messages."
  @spec force_unscoped(mc()) :: result()
  def force_unscoped(mc), do: set_flood_scope(mc, {:key, <<>>}, force_unscoped: true)

  @doc """
  Sets the device's default flood scope region (`nil`, `""`, `"0"`, `"None"`
  or `"*"` disable it). Raises `ArgumentError` for names of 31 bytes or more.
  """
  @spec set_default_flood_scope(mc(), String.t() | nil) :: result()
  def set_default_flood_scope(mc, scope) when is_nil(scope) or is_binary(scope) do
    code = Packets.command(:set_default_flood_scope)

    if scope in [nil, "0", "None", "*", ""] do
      Logger.debug("Resetting default scope")
      send_ok(mc, <<code>>)
    else
      name = if String.starts_with?(scope, "#"), do: scope, else: "#" <> scope

      if byte_size(name) >= 31,
        do: raise(ArgumentError, "Scope name must be shorter than 31 bytes")

      padding = :binary.copy(<<0>>, 31 - byte_size(name))
      send_ok(mc, <<code>> <> name <> padding <> scope_key(name))
    end
  end

  @doc "Disables the default flood scope."
  @spec reset_default_flood_scope(mc()) :: result()
  def reset_default_flood_scope(mc), do: set_default_flood_scope(mc, nil)

  @doc "Reads the default flood scope (`:default_flood_scope`)."
  @spec get_default_flood_scope(mc()) :: result()
  def get_default_flood_scope(mc),
    do:
      send_command(mc, <<Packets.command(:get_default_flood_scope)>>, [
        :default_flood_scope,
        :error
      ])

  @doc false
  def then_spec(types, opts, extra \\ %{}) do
    Map.merge(
      %{
        types: types,
        timeout: opts[:timeout] || 0,
        min_timeout: opts[:min_timeout] || 0
      },
      extra
    )
  end
end
