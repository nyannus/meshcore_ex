defmodule Meshcore.Transport.BLE do
  @moduledoc """
  Bluetooth Low Energy transport (Nordic UART service).

  There is no mature cross-platform BLE stack on the BEAM, so this transport
  contains the **MeshCore-specific logic** – serialised writes with a hard
  timeout, optional PIN pairing, "tear the link down on a stalled write" – and
  delegates the radio work to a pluggable `Meshcore.Transport.BLE.Adapter`.

  Options:

    * `:adapter` (required) – module implementing `Meshcore.Transport.BLE.Adapter`
    * `:address` – BLE address (or part of the advertised name) to connect to;
      when `nil` or not an address the adapter scans for a `MeshCore*` device
    * `:pin` – PIN to pair with after connecting
    * `:write_timeout` – milliseconds before a write is considered stalled (default `10_000`)
    * `:adapter_opts` – extra keyword options passed to the adapter

  The Nordic UART UUIDs are exposed as `uart_service_uuid/0`,
  `uart_rx_char_uuid/0` (write) and `uart_tx_char_uuid/0` (notify).
  """

  @behaviour Meshcore.Transport
  use GenServer
  require Logger

  alias Meshcore.Transport

  @uart_service "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
  @uart_rx "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
  @uart_tx "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
  @write_timeout 10_000

  @doc "Nordic UART service UUID."
  def uart_service_uuid, do: @uart_service
  @doc "RX characteristic UUID (the host writes commands here)."
  def uart_rx_char_uuid, do: @uart_rx
  @doc "TX characteristic UUID (the device notifies frames here)."
  def uart_tx_char_uuid, do: @uart_tx

  @impl Meshcore.Transport
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Meshcore.Transport
  def send_frame(pid, frame), do: GenServer.cast(pid, {:send, frame})

  @impl Meshcore.Transport
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      adapter: Keyword.fetch!(opts, :adapter),
      address: Keyword.get(opts, :address),
      pin: Keyword.get(opts, :pin),
      write_timeout: Keyword.get(opts, :write_timeout, @write_timeout),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      handle: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    adapter_opts =
      Keyword.merge(state.adapter_opts,
        address: state.address,
        service_uuid: @uart_service,
        rx_char_uuid: @uart_rx,
        tx_char_uuid: @uart_tx,
        name_prefix: "MeshCore"
      )

    with {:ok, handle, address} <- state.adapter.connect(self(), adapter_opts),
         :ok <- maybe_pair(state, handle) do
      Transport.notify(state.owner, {:connected, address})
      {:noreply, %{state | handle: handle}}
    else
      {:error, reason} ->
        Transport.notify(state.owner, {:disconnected, {:connect_failed, reason}})
        {:stop, :normal, state}
    end
  end

  defp maybe_pair(%{pin: nil}, _handle), do: :ok

  defp maybe_pair(%{pin: pin, adapter: adapter}, handle) do
    case adapter.pair(handle, pin) do
      :ok ->
        Logger.info("BLE pairing successful")
        :ok

      {:error, reason} ->
        # a failed pairing leaves the link half-usable, fail cleanly
        Logger.error("BLE pairing failed: #{inspect(reason)}")
        adapter.disconnect(handle)
        {:error, {:pairing_failed, reason}}
    end
  end

  @impl GenServer
  def handle_cast({:send, _}, %{handle: nil} = state), do: {:noreply, state}

  def handle_cast({:send, frame}, state) do
    # Run the write in a task so a stalled BLE stack cannot freeze this process
    # forever. Writes are naturally serialised by this process' mailbox, which
    # matters: overlapping writes to the same characteristic drop the link.
    task = Task.async(fn -> state.adapter.write(state.handle, frame) end)

    case Task.yield(task, state.write_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        {:noreply, state}

      {:ok, {:error, reason}} ->
        Logger.warning("BLE write failed: #{inspect(reason)}")
        Transport.notify(state.owner, {:disconnected, {:ble_write_failed, reason}})
        {:stop, :normal, state}

      _timeout_or_exit ->
        # The write may still be in flight; a second write racing it kills the
        # link, so tear it down and let the client reconnect.
        Logger.warning("BLE write timed out after #{state.write_timeout}ms")
        Transport.notify(state.owner, {:disconnected, :ble_write_timeout})
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info({:ble_data, data}, state) when is_binary(data) do
    Transport.notify(state.owner, {:frame, data})
    {:noreply, state}
  end

  def handle_info({:ble_disconnected, reason}, state) do
    Logger.debug("BLE device disconnected: #{inspect(reason)}")
    Transport.notify(state.owner, {:disconnected, :ble_disconnect})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{handle: handle, adapter: adapter}) when handle != nil do
    adapter.disconnect(handle)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
