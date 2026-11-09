defmodule Meshcore.Transport.Serial do
  @moduledoc """
  Serial (USB/UART) transport built on [`circuits_uart`](https://hex.pm/packages/circuits_uart).

  `circuits_uart` is an *optional* dependency – add it to your own `mix.exs`
  to use serial connections:

      {:circuits_uart, "~> 1.5"}

  Options: `:port` (required, e.g. `"/dev/ttyUSB0"`), `:baudrate` (default
  `115200`), `:dtr` (default `true`), `:rts` (default `false`) and `:cx_delay`
  (milliseconds to wait after opening, default `100`).

  Some boards (e.g. Heltec V2) reset when DTR is asserted – if you get no
  response try `dtr: false`. `Meshcore.create_serial/2` retries automatically
  with the inverted DTR.
  """

  @behaviour Meshcore.Transport
  use GenServer
  require Logger

  alias Meshcore.{Frame, Transport}

  @compile {:no_warn_undefined, Circuits.UART}

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
      port: Keyword.fetch!(opts, :port),
      baudrate: Keyword.get(opts, :baudrate, 115_200),
      dtr: Keyword.get(opts, :dtr, true),
      rts: Keyword.get(opts, :rts, false),
      cx_delay: Keyword.get(opts, :cx_delay, 100),
      uart: nil,
      frame: Frame.new()
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state) do
    if Code.ensure_loaded?(Circuits.UART) do
      open(state)
    else
      Logger.error("Meshcore.Transport.Serial requires the optional :circuits_uart dependency")
      Transport.notify(state.owner, {:disconnected, {:connect_failed, :circuits_uart_missing}})
      {:stop, :normal, state}
    end
  end

  defp open(state) do
    {:ok, uart} = Circuits.UART.start_link()

    case Circuits.UART.open(uart, state.port, speed: state.baudrate, active: true) do
      :ok ->
        Circuits.UART.set_dtr(uart, state.dtr)
        Circuits.UART.set_rts(uart, state.rts)
        if state.cx_delay > 0, do: Process.sleep(state.cx_delay)
        Transport.notify(state.owner, {:connected, state.port})
        {:noreply, %{state | uart: uart}}

      {:error, reason} ->
        Circuits.UART.stop(uart)
        Transport.notify(state.owner, {:disconnected, {:connect_failed, reason}})
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_cast({:send, _}, %{uart: nil} = state), do: {:noreply, state}

  def handle_cast({:send, frame}, state) do
    case Circuits.UART.write(state.uart, Frame.encode(frame)) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Serial write failed: #{inspect(reason)}")
        Transport.notify(state.owner, {:disconnected, {:serial_write_failed, reason}})
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {frames, frame_state} = Frame.decode(state.frame, data)
    Enum.each(frames, &Transport.notify(state.owner, {:frame, &1}))
    {:noreply, %{state | frame: frame_state}}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.debug("Serial port closed: #{inspect(reason)}")
    Transport.notify(state.owner, {:disconnected, :serial_disconnect})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{uart: uart}) when uart != nil do
    Circuits.UART.close(uart)
    Circuits.UART.stop(uart)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
