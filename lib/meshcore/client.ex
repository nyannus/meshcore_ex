defmodule Meshcore.Client do
  @moduledoc """
  The session process behind a MeshCore connection.

  One `Meshcore.Client` owns

    * the transport process (and reconnects it when `auto_reconnect` is on),
    * the `Meshcore.Reader` that turns frames into events,
    * the list of event subscribers and of commands waiting for a response,
    * the contact list / self info / device time mirrored from the device,
    * a FIFO lock serialising "mesh requests" (login, status, telemetry…).

  You normally use it through `Meshcore` and `Meshcore.Commands`; the functions
  here are the lower-level building blocks.

  ## Fault tolerance

    * Commands are never answered by blocking the process: each one registers
      a *waiter* with a timer, so a silent device produces
      `{:error, %Meshcore.Event{type: :error, payload: %{reason: :timeout}}}`
      rather than a hang.
    * Waiters are failed immediately with `reason: :disconnected` when the link
      drops.
    * Subscribers are monitored; dead ones are dropped automatically.
    * The lock holder is monitored; a crashed holder releases the lock.
    * Decoding errors are contained in `Meshcore.Reader`.
    * A crashed transport is just another lost connection.
  """

  use GenServer, restart: :transient
  require Logger

  alias Meshcore.{Event, Reader, Subscription}

  @default_timeout 15_000
  @appstart_timeout 2_000
  @backoff_cap 8_000

  @type t :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts a client. See `Meshcore.start_link/1` for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends `data` and waits for one of the `expected` event types.

  With an empty `expected` list the command is fire-and-forget and returns
  `{:ok, %Event{type: :ok, payload: %{}}}` immediately.

  Options:

    * `:timeout` – milliseconds (default: the client's default timeout)
    * `:touch_on` – event types that restart the timeout (used for contact lists)
    * `:register` – registers a binary request as soon as `:msg_sent` arrives
      (race-free); a map with `:prefix`, `:request_type`, `:timeout`,
      `:min_timeout`, `:context`, `:is_anon`, `:hops`
    * `:then` – after `:msg_sent`, keep waiting for a follow-up event; a map
      with `:types`, `:filters`, `:tag_filter` (boolean), `:timeout`,
      `:min_timeout`
  """
  @spec command(t(), binary(), [Event.type()], keyword()) :: result()
  def command(mc, data, expected, opts \\ []) when is_binary(data) do
    GenServer.call(mc, {:command, data, List.wrap(expected), opts}, :infinity)
  end

  @doc """
  Waits for an event of `type` (or any of a list of types) whose attributes
  match `filters`. Returns `{:ok, event}` or `{:error, :timeout}`.
  """
  @spec wait_for_event(
          t(),
          Event.type() | [Event.type()],
          map(),
          timeout_ms :: non_neg_integer() | nil
        ) ::
          {:ok, Event.t()} | {:error, :timeout}
  def wait_for_event(mc, type, filters \\ %{}, timeout \\ nil) do
    GenServer.call(mc, {:wait_for_event, List.wrap(type), Map.new(filters), timeout}, :infinity)
  end

  @doc "Subscribes `pid` to events. See `Meshcore.subscribe/3`."
  @spec subscribe(t(), atom() | [atom()] | nil, map(), pid()) :: {:ok, Subscription.t()}
  def subscribe(mc, types, filters, pid) do
    GenServer.call(mc, {:subscribe, normalize_types(types), Map.new(filters), pid})
  end

  @doc "Removes a subscription (idempotent)."
  @spec unsubscribe(t(), Subscription.t() | reference()) :: :ok
  def unsubscribe(mc, %Subscription{ref: ref}), do: unsubscribe(mc, ref)
  def unsubscribe(mc, ref) when is_reference(ref), do: GenServer.call(mc, {:unsubscribe, ref})

  @doc "Connects the transport and runs the app-start handshake."
  @spec connect(t()) :: result() | {:error, term()}
  def connect(mc), do: GenServer.call(mc, :connect, :infinity)

  @doc "Disconnects and stops the client process."
  @spec disconnect(t()) :: :ok
  def disconnect(mc) do
    GenServer.call(mc, :disconnect, 10_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Runs `fun` while holding the per-connection mesh request lock.

  The lock is FIFO, released automatically if the holder crashes and
  re-entrant for the process that holds it.
  """
  @spec with_lock(t(), (-> result)) :: result when result: term()
  def with_lock(mc, fun) when is_function(fun, 0) do
    key = {:meshcore_lock, mc}

    if Process.get(key) do
      fun.()
    else
      :ok = GenServer.call(mc, :acquire_lock, :infinity)
      Process.put(key, true)

      try do
        fun.()
      after
        Process.delete(key)
        GenServer.cast(mc, {:release_lock, self()})
      end
    end
  end

  @doc "Reads a value of the mirrored session state. See `Meshcore` getters."
  @spec get(t(), atom()) :: term()
  def get(mc, key), do: GenServer.call(mc, {:get, key})

  @doc "Sets a session setting (`:auto_update_contacts`, `:default_timeout`, `:decrypt_channels`)."
  @spec put(t(), atom(), term()) :: :ok
  def put(mc, key, value), do: GenServer.call(mc, {:put, key, value})

  @doc false
  def call(mc, request), do: GenServer.call(mc, request)

  @doc false
  def cast(mc, request), do: GenServer.cast(mc, request)

  defp normalize_types(nil), do: :all
  defp normalize_types(:all), do: :all
  defp normalize_types(type) when is_atom(type), do: [type]
  defp normalize_types(types) when is_list(types), do: types

  # ===========================================================================
  # GenServer
  # ===========================================================================

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Keyword.get(opts, :log_level) do
      nil -> :ok
      level -> Logger.put_process_level(self(), level)
    end

    state = %{
      transport_spec: Keyword.fetch!(opts, :transport),
      transport: nil,
      status: :disconnected,
      reconnecting: false,
      reconnect_timer: nil,
      reconnect_attempts: 0,
      auto_reconnect: Keyword.get(opts, :auto_reconnect, false),
      max_reconnect_attempts: Keyword.get(opts, :max_reconnect_attempts, 3),
      default_timeout: Keyword.get(opts, :default_timeout) || @default_timeout,
      reader: Reader.new(),
      subscribers: %{},
      monitors: %{},
      waiters: [],
      next_waiter_id: 1,
      connect_waiters: [],
      lock_holder: nil,
      lock_queue: :queue.new(),
      contacts: %{},
      contacts_dirty: true,
      pending_contacts: %{},
      self_info: %{},
      time: 0,
      lastmod: 0,
      auto_update_contacts: false,
      auto_fetch: false,
      fetch_task: nil,
      factory_reset_token: nil
    }

    if Keyword.get(opts, :connect, true) do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, start_transport(state)}

  # -- calls -------------------------------------------------------------------

  @impl GenServer
  def handle_call({:command, data, expected, opts}, from, state) do
    cond do
      state.status != :connected ->
        {:reply, {:error, Event.error(:not_connected)}, state}

      expected == [] ->
        transmit(state, data)
        {:reply, {:ok, Event.new(:ok, %{})}, state}

      true ->
        timeout = Keyword.get(opts, :timeout) || state.default_timeout

        waiter = %{
          reply: {:call, from},
          types: expected,
          filters: %{},
          mode: :command,
          timeout: timeout,
          touch_on: Keyword.get(opts, :touch_on, []),
          register: Keyword.get(opts, :register),
          then: Keyword.get(opts, :then),
          plain_timeout: false
        }

        state = add_waiter(state, waiter)
        transmit(state, data)
        {:noreply, state}
    end
  end

  def handle_call({:wait_for_event, types, filters, timeout}, from, state) do
    waiter = %{
      reply: {:call, from},
      types: types,
      filters: filters,
      mode: :wait,
      timeout: timeout || state.default_timeout,
      touch_on: [],
      register: nil,
      then: nil,
      plain_timeout: true
    }

    {:noreply, add_waiter(state, waiter)}
  end

  def handle_call({:subscribe, types, filters, pid}, _from, state) do
    ref = make_ref()
    {_mon, monitors} = monitor_for(state.monitors, pid)
    sub = %{pid: pid, types: types, filters: filters}
    state = %{state | subscribers: Map.put(state.subscribers, ref, sub), monitors: monitors}
    {:reply, {:ok, %Subscription{ref: ref, mc: self_ref()}}, state}
  end

  def handle_call({:unsubscribe, ref}, _from, state),
    do: {:reply, :ok, drop_subscription(state, ref)}

  def handle_call(:connect, _from, %{status: :connected} = state),
    do: {:reply, {:ok, Event.new(:self_info, state.self_info)}, state}

  def handle_call(:connect, from, %{status: :connecting} = state),
    do: {:noreply, %{state | connect_waiters: [from | state.connect_waiters]}}

  def handle_call(:connect, from, state) do
    state = %{state | connect_waiters: [from | state.connect_waiters], reconnecting: false}
    {:noreply, start_transport(state)}
  end

  def handle_call(:disconnect, _from, state) do
    state = fail_all_waiters(state, :disconnected)

    if state.status == :connected do
      notify(state, Event.new(:disconnected, %{reason: "manual_disconnect"}))
    end

    {:stop, :normal, :ok, close_transport(state)}
  end

  def handle_call(:acquire_lock, {pid, _} = from, state) do
    case state.lock_holder do
      nil ->
        {:reply, :ok, %{state | lock_holder: {pid, Process.monitor(pid)}}}

      _holder ->
        {:noreply, %{state | lock_queue: :queue.in({from, pid}, state.lock_queue)}}
    end
  end

  def handle_call({:get, key}, _from, state), do: {:reply, get_value(state, key), state}

  def handle_call({:put, :auto_update_contacts, v}, _from, state),
    do: {:reply, :ok, %{state | auto_update_contacts: v}}

  def handle_call({:put, :default_timeout, v}, _from, state),
    do: {:reply, :ok, %{state | default_timeout: v}}

  def handle_call({:put, :decrypt_channels, v}, _from, state),
    do: {:reply, :ok, %{state | reader: Reader.set_decrypt_channels(state.reader, v)}}

  def handle_call({:put, :pending_contacts, v}, _from, state),
    do: {:reply, :ok, %{state | pending_contacts: v}}

  def handle_call({:pop_pending_contact, key}, _from, state) do
    {contact, pending} = Map.pop(state.pending_contacts, key)
    {:reply, contact, %{state | pending_contacts: pending}}
  end

  def handle_call({:contact_by_name, name}, _from, state) do
    name = String.downcase(name)

    contact =
      Enum.find_value(state.contacts, fn {_k, c} ->
        if String.downcase(Map.get(c, :adv_name, "")) == name, do: c
      end)

    {:reply, contact, state}
  end

  def handle_call({:contact_by_prefix, prefix}, _from, state),
    do: {:reply, find_by_prefix(state.contacts, prefix), state}

  def handle_call({:set_auto_fetch, true}, _from, state),
    do: {:reply, :ok, maybe_fetch(%{state | auto_fetch: true})}

  def handle_call({:set_auto_fetch, false}, _from, state) do
    if state.fetch_task,
      do: Task.Supervisor.terminate_child(Meshcore.TaskSupervisor, state.fetch_task.pid)

    {:reply, :ok, %{state | auto_fetch: false, fetch_task: nil}}
  end

  def handle_call({:factory_reset_token, token}, _from, state),
    do: {:reply, :ok, %{state | factory_reset_token: token}}

  def handle_call(:take_factory_reset_token, _from, state),
    do: {:reply, state.factory_reset_token, %{state | factory_reset_token: nil}}

  # -- casts -------------------------------------------------------------------

  @impl GenServer
  def handle_cast({:release_lock, pid}, %{lock_holder: {pid, mon}} = state) do
    Process.demonitor(mon, [:flush])
    {:noreply, next_lock_holder(%{state | lock_holder: nil})}
  end

  def handle_cast({:release_lock, _other}, state), do: {:noreply, state}

  def handle_cast({:update_contact, key, changes}, state) do
    contacts =
      case state.contacts do
        %{^key => c} -> Map.put(state.contacts, key, Map.merge(c, changes))
        contacts -> contacts
      end

    {:noreply, %{state | contacts: contacts}}
  end

  # -- messages ---------------------------------------------------------------

  @impl GenServer
  def handle_info({:meshcore_transport, pid, message}, %{transport: %{pid: pid}} = state),
    do: {:noreply, handle_transport(message, state)}

  def handle_info({:meshcore_transport, _stale, _message}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{transport: %{pid: pid}} = state) do
    Logger.warning("Transport exited: #{inspect(reason)}")
    {:noreply, transport_lost(%{state | transport: nil}, {:transport_exit, reason})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:waiter_timeout, id}, state), do: {:noreply, waiter_timed_out(state, id)}

  def handle_info(:reconnect, state) do
    {:noreply, start_transport(%{state | reconnect_timer: nil, reconnecting: true})}
  end

  def handle_info({:DOWN, mon, :process, pid, _reason}, state) do
    cond do
      match?({^pid, ^mon}, state.lock_holder) ->
        {:noreply, next_lock_holder(%{state | lock_holder: nil})}

      match?(%{ref: ^mon}, state.fetch_task) ->
        {:noreply, %{state | fetch_task: nil}}

      true ->
        state = remove_lock_waiter(state, pid)
        {:noreply, drop_subscriber(state, pid)}
    end
  end

  # Task.Supervisor.async_nolink result
  def handle_info({ref, _result}, %{fetch_task: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | fetch_task: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close_transport(state)
    :ok
  end

  # ===========================================================================
  # Transport / connection management
  # ===========================================================================

  defp start_transport(state) do
    {mod, opts} = state.transport_spec

    case mod.start_link(Keyword.put(opts, :owner, self())) do
      {:ok, pid} ->
        %{state | transport: %{pid: pid, mod: mod}, status: :connecting}

      {:error, reason} ->
        connect_failed(%{state | transport: nil}, {:start_failed, reason})
    end
  rescue
    e ->
      connect_failed(%{state | transport: nil}, {:start_failed, Exception.message(e)})
  end

  defp handle_transport({:connected, info}, state) do
    Logger.debug("Transport connected: #{inspect(info)}")
    state = %{state | status: :connected}

    if state.reconnecting do
      state = %{state | reconnect_attempts: 0}
      start_appstart(state, {:reconnected, info})
    else
      state = notify_and_track(state, Event.new(:connected, %{connection_info: info}))
      start_appstart(state, {:initial, info})
    end
  end

  defp handle_transport({:frame, data}, state), do: process_frame(state, data)

  defp handle_transport({:disconnected, {:connect_failed, reason}}, state),
    do: connect_failed(%{state | transport: nil}, reason)

  defp handle_transport({:disconnected, reason}, state) do
    transport_lost(%{state | transport: nil}, reason)
  end

  defp start_appstart(state, tag) do
    waiter = %{
      reply: {:internal, {:appstart, tag}},
      types: [:self_info, :error],
      filters: %{},
      mode: :command,
      timeout: @appstart_timeout,
      touch_on: [],
      register: nil,
      then: nil,
      plain_timeout: false
    }

    state = add_waiter(state, waiter)
    transmit(state, <<0x01, 0x03, "      mccli">>)
    state
  end

  defp handle_internal({:appstart, {:initial, _info}}, result, state) do
    {replies, state} = take_connect_waiters(state)
    Enum.each(replies, &GenServer.reply(&1, result))
    state
  end

  defp handle_internal({:appstart, {:reconnected, info}}, result, state) do
    case result do
      {:ok, _} -> Logger.debug("Reconnected, app-start succeeded")
      {:error, event} -> Logger.warning("Reconnect app-start failed: #{inspect(event.payload)}")
    end

    state = %{state | reconnecting: false}
    notify_and_track(state, Event.new(:connected, %{connection_info: info, reconnected: true}))
  end

  # The very first connect failed (or a start_link failure).
  defp connect_failed(state, reason) do
    state = %{state | status: :disconnected}

    cond do
      state.connect_waiters != [] and not state.reconnecting ->
        {replies, state} = take_connect_waiters(state)
        Enum.each(replies, &GenServer.reply(&1, {:error, {:connect_failed, reason}}))
        state

      true ->
        lost(state, "connect_failed: #{inspect(reason)}")
    end
  end

  defp transport_lost(%{status: :disconnected} = state, _reason), do: state

  defp transport_lost(state, reason) do
    state = %{state | status: :disconnected}
    state = fail_all_waiters(state, :disconnected)

    {replies, state} = take_connect_waiters(state)
    Enum.each(replies, &GenServer.reply(&1, {:error, {:disconnected, reason}}))

    lost(state, to_reason(reason))
  end

  # Connection is gone: reconnect or announce the disconnect.
  defp lost(state, reason) do
    cond do
      state.auto_reconnect and state.reconnect_attempts < state.max_reconnect_attempts ->
        schedule_reconnect(state)

      true ->
        payload =
          if state.reconnecting or state.reconnect_attempts > 0 do
            %{reason: "reconnect_failed", max_attempts_exceeded: true}
          else
            %{
              reason: reason,
              reconnect_failed: state.reconnect_attempts >= state.max_reconnect_attempts
            }
          end

        state = %{state | reconnecting: false}
        notify_and_track(state, Event.new(:disconnected, payload))
    end
  end

  defp schedule_reconnect(state) do
    attempts = state.reconnect_attempts + 1
    delay = min(1_000 * Integer.pow(2, attempts - 1), @backoff_cap)
    Logger.debug("Reconnect attempt #{attempts}/#{state.max_reconnect_attempts} in #{delay}ms")
    timer = Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_attempts: attempts, reconnect_timer: timer, reconnecting: true}
  end

  defp close_transport(%{transport: nil} = state), do: state

  defp close_transport(%{transport: %{pid: pid, mod: mod}} = state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    mod.close(pid)
    %{state | transport: nil, status: :disconnected, reconnect_timer: nil}
  end

  defp take_connect_waiters(state),
    do: {Enum.reverse(state.connect_waiters), %{state | connect_waiters: []}}

  defp to_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_reason(reason), do: inspect(reason)

  defp transmit(%{transport: %{pid: pid, mod: mod}}, data) do
    Logger.debug(fn -> "Sending raw data: #{Base.encode16(data, case: :lower)}" end)
    mod.send_frame(pid, data)
  end

  defp transmit(_state, _data), do: :ok

  # ===========================================================================
  # Frames, events and waiters
  # ===========================================================================

  defp process_frame(state, data) do
    {events, reader} = Reader.handle_rx(state.reader, data)
    Enum.reduce(events, %{state | reader: reader}, &dispatch_event/2)
  end

  defp dispatch_event(%Event{} = event, state) do
    state
    |> track(event)
    |> resolve_waiters(event)
    |> tap(&notify(&1, event))
  end

  defp notify_and_track(state, event), do: dispatch_event(event, state)

  defp notify(state, %Event{type: type} = event) do
    for {ref, %{pid: pid, types: types, filters: filters}} <- state.subscribers,
        types == :all or type in types,
        Event.match_filters?(event, filters) do
      send(pid, {:meshcore, ref, event})
    end

    :ok
  end

  # -- state mirroring (Python's _setup_data_tracking) --------------------------

  defp track(state, %Event{type: :contacts, payload: payload, attributes: attrs}) do
    contacts =
      Enum.reduce(payload, state.contacts, fn {_k, c}, acc ->
        Map.update(acc, c.public_key, c, &Map.merge(&1, c))
      end)

    %{
      state
      | contacts: contacts,
        lastmod: Map.get(attrs, :lastmod, state.lastmod),
        contacts_dirty: false
    }
  end

  defp track(state, %Event{type: :new_contact, payload: c}),
    do: %{state | pending_contacts: Map.put(state.pending_contacts, c.public_key, c)}

  defp track(state, %Event{type: :self_info, payload: info}), do: %{state | self_info: info}

  defp track(state, %Event{type: :current_time, payload: p}),
    do: %{state | time: Map.get(p, :time, 0)}

  defp track(state, %Event{type: type}) when type in [:advertisement, :path_update] do
    state = %{state | contacts_dirty: true}

    if state.auto_update_contacts do
      mc = self()

      Task.Supervisor.start_child(Meshcore.TaskSupervisor, fn ->
        Meshcore.ensure_contacts(mc, true)
      end)
    end

    state
  end

  defp track(state, %Event{type: :messages_waiting}), do: maybe_fetch(state)
  defp track(state, _event), do: state

  defp maybe_fetch(%{auto_fetch: true, fetch_task: nil, status: :connected} = state) do
    mc = self()

    task =
      Task.Supervisor.async_nolink(Meshcore.TaskSupervisor, fn ->
        Meshcore.Client.fetch_loop(mc)
      end)

    %{state | fetch_task: task}
  end

  defp maybe_fetch(state), do: state

  @doc false
  # Pulls queued messages until the device reports none left (or an error).
  def fetch_loop(mc) do
    case Meshcore.Commands.Messaging.get_msg(mc) do
      {:ok, %Event{type: :no_more_msgs}} ->
        :ok

      {:ok, _event} ->
        Process.sleep(100)
        fetch_loop(mc)

      {:error, _} ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  # -- waiters --------------------------------------------------------------------

  defp add_waiter(state, waiter) do
    id = state.next_waiter_id
    timer = Process.send_after(self(), {:waiter_timeout, id}, waiter.timeout)
    waiter = Map.merge(waiter, %{id: id, timer: timer})
    %{state | waiters: state.waiters ++ [waiter], next_waiter_id: id + 1}
  end

  defp resolve_waiters(state, event) do
    {survivors, done, state, _consumed} =
      Enum.reduce(state.waiters, {[], [], state, false}, fn waiter, {keep, done, st, consumed} ->
        cond do
          not matches?(waiter, event) and event.type in waiter.touch_on ->
            {[refresh_timer(waiter) | keep], done, st, consumed}

          not matches?(waiter, event) ->
            {[waiter | keep], done, st, consumed}

          waiter.mode == :command and consumed ->
            {[waiter | keep], done, st, consumed}

          true ->
            exclusive? = waiter.mode == :command

            case on_match(waiter, event, st) do
              {:done, result, st} ->
                {keep, [{waiter, result} | done], st, consumed or exclusive?}

              {:continue, waiter, st} ->
                {[waiter | keep], done, st, consumed or exclusive?}
            end
        end
      end)

    # Install the surviving waiters *before* answering anyone: answering an
    # internal waiter may dispatch further events and must see a coherent list.
    state = %{state | waiters: Enum.reverse(survivors)}

    done
    |> Enum.reverse()
    |> Enum.reduce(state, fn {waiter, result}, st -> answer(waiter, result, st) end)
  end

  defp matches?(waiter, event),
    do: event.type in waiter.types and Event.match_filters?(event, waiter.filters)

  defp refresh_timer(waiter) do
    Process.cancel_timer(waiter.timer)
    %{waiter | timer: Process.send_after(self(), {:waiter_timeout, waiter.id}, waiter.timeout)}
  end

  # Called when `event` satisfies `waiter`. Returns `{:done, result, state}` when
  # the waiter is to be answered, or `{:continue, waiter, state}` when it moves
  # on to a follow-up phase.
  defp on_match(waiter, %Event{type: :msg_sent} = event, state) do
    {event, state} = apply_register(waiter, event, state)

    case waiter.then do
      nil ->
        finish(waiter, event, state)

      then ->
        timeout = then_timeout(then, event)
        Process.cancel_timer(waiter.timer)
        timer = Process.send_after(self(), {:waiter_timeout, waiter.id}, timeout)

        filters = Map.get(then, :filters, %{})

        filters =
          if Map.get(then, :tag_filter),
            do: Map.put(filters, :tag, Base.encode16(event.payload.expected_ack, case: :lower)),
            else: filters

        {:continue,
         %{
           waiter
           | types: then.types,
             filters: filters,
             mode: :wait,
             timeout: timeout,
             timer: timer,
             then: nil,
             touch_on: [],
             plain_timeout: false
         }, state}
    end
  end

  defp on_match(waiter, event, state), do: finish(waiter, event, state)

  defp finish(waiter, event, state) do
    Process.cancel_timer(waiter.timer)
    {:done, Event.to_result(event), state}
  end

  defp answer(%{reply: {:call, from}}, result, state) do
    GenServer.reply(from, result)
    state
  end

  defp answer(%{reply: {:internal, tag}}, result, state), do: handle_internal(tag, result, state)

  defp apply_register(%{register: nil}, event, state), do: {event, state}

  defp apply_register(%{register: reg}, event, state) do
    suggested = Map.get(event.payload, :suggested_timeout, 4000)
    hops = Map.get(reg, :hops)

    {suggested, event} =
      if hops do
        s = suggested * (hops + 1)
        {s, %{event | payload: Map.put(event.payload, :suggested_timeout, s)}}
      else
        {suggested, event}
      end

    timeout = reg_timeout(Map.get(reg, :timeout, 0), Map.get(reg, :min_timeout, 0), suggested)
    tag = Base.encode16(event.payload.expected_ack, case: :lower)

    reader =
      Reader.register_binary_request(state.reader, reg.prefix, tag, reg.request_type, timeout,
        context: Map.get(reg, :context, %{}),
        is_anon: Map.get(reg, :is_anon, false)
      )

    {event, %{state | reader: reader}}
  end

  # Python: `suggested_timeout / 800` seconds, i.e. suggested * 1.25 ms.
  defp reg_timeout(timeout, min_timeout, suggested) do
    t = if timeout > 0, do: timeout, else: trunc(suggested * 1.25)
    max(t, min_timeout)
  end

  defp then_timeout(then, event) do
    suggested = Map.get(event.payload, :suggested_timeout, 4000)
    reg_timeout(Map.get(then, :timeout, 0), Map.get(then, :min_timeout, 0), suggested)
  end

  defp waiter_timed_out(state, id) do
    case Enum.split_with(state.waiters, &(&1.id == id)) do
      {[], _} ->
        state

      {[waiter], rest} ->
        result =
          if waiter.plain_timeout,
            do: {:error, :timeout},
            else: {:error, Event.error(:timeout)}

        answer(waiter, result, %{state | waiters: rest})
    end
  end

  defp fail_all_waiters(state, reason) do
    waiters = state.waiters
    state = %{state | waiters: []}

    Enum.reduce(waiters, state, fn waiter, st ->
      Process.cancel_timer(waiter.timer)

      result =
        if waiter.plain_timeout, do: {:error, reason}, else: {:error, Event.error(reason)}

      answer(waiter, result, st)
    end)
  end

  # ===========================================================================
  # Subscribers, lock, getters
  # ===========================================================================

  defp monitor_for(monitors, pid) do
    case monitors do
      %{^pid => mon} ->
        {mon, monitors}

      _ ->
        mon = Process.monitor(pid)
        {mon, Map.put(monitors, pid, mon)}
    end
  end

  defp drop_subscription(state, ref) do
    case Map.pop(state.subscribers, ref) do
      {nil, _} ->
        state

      {%{pid: pid}, subs} ->
        state = %{state | subscribers: subs}

        if Enum.any?(subs, fn {_r, s} -> s.pid == pid end) do
          state
        else
          {mon, monitors} = Map.pop(state.monitors, pid)
          if mon, do: Process.demonitor(mon, [:flush])
          %{state | monitors: monitors}
        end
    end
  end

  defp drop_subscriber(state, pid) do
    subs = Map.reject(state.subscribers, fn {_r, s} -> s.pid == pid end)
    %{state | subscribers: subs, monitors: Map.delete(state.monitors, pid)}
  end

  defp next_lock_holder(state) do
    case :queue.out(state.lock_queue) do
      {{:value, {from, pid}}, queue} ->
        GenServer.reply(from, :ok)
        %{state | lock_holder: {pid, Process.monitor(pid)}, lock_queue: queue}

      {:empty, _} ->
        state
    end
  end

  defp remove_lock_waiter(state, pid) do
    queue = :queue.filter(fn {_from, p} -> p != pid end, state.lock_queue)
    %{state | lock_queue: queue}
  end

  defp self_ref, do: self()

  defp get_value(state, :contacts), do: state.contacts
  defp get_value(state, :contacts_dirty), do: state.contacts_dirty
  defp get_value(state, :auto_update_contacts), do: state.auto_update_contacts
  defp get_value(state, :self_info), do: state.self_info
  defp get_value(state, :time), do: state.time
  defp get_value(state, :lastmod), do: state.lastmod
  defp get_value(state, :connected), do: state.status == :connected
  defp get_value(state, :status), do: state.status
  defp get_value(state, :default_timeout), do: state.default_timeout
  defp get_value(state, :pending_contacts), do: state.pending_contacts
  defp get_value(state, :decrypt_channels), do: Reader.decrypt_channels?(state.reader)
  defp get_value(state, :auto_fetch), do: state.auto_fetch

  defp find_by_prefix(_contacts, prefix) when prefix in [nil, ""], do: nil

  defp find_by_prefix(contacts, prefix) do
    prefix = String.downcase(prefix)

    Enum.find_value(contacts, fn {_k, c} ->
      if c |> Map.get(:public_key, "") |> String.downcase() |> String.starts_with?(prefix), do: c
    end)
  end
end
