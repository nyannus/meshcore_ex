defmodule Meshcore.Transport.TCP do
  @moduledoc """
  TCP transport (e.g. a WiFi companion firmware or a serial-to-TCP bridge).

  Options: `:host` (required), `:port` (required), `:connect_timeout`
  (milliseconds, default `10_000`).

  Like the Python implementation it detects half-dead connections: if
  #{5} requests in a row were sent without any frame coming back, the link is
  reported as lost (`:tcp_no_response`) so the client can reconnect.
  """

  @behaviour Meshcore.Transport
  use GenServer
  require Logger

  alias Meshcore.{Frame, Transport}

  @disconnect_threshold 5

  # -- Transport API ---------------------------------------------------------

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

  # -- GenServer ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
      socket: nil,
      frame: Frame.new(),
      sent: 0,
      received: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    host = to_host(state.host)
    sock_opts = [:binary, active: :once, packet: :raw, nodelay: true]

    case :gen_tcp.connect(host, state.port, sock_opts, state.connect_timeout) do
      {:ok, socket} ->
        Transport.notify(state.owner, {:connected, state.host})
        {:noreply, %{state | socket: socket}}

      {:error, reason} ->
        Transport.notify(state.owner, {:disconnected, {:connect_failed, reason}})
        {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_cast({:send, _frame}, %{socket: nil} = state), do: {:noreply, state}

  def handle_cast({:send, frame}, state) do
    if state.sent - state.received >= @disconnect_threshold do
      Logger.debug("TCP disconnect detected: sent #{state.sent}, received #{state.received}")
      Transport.notify(state.owner, {:disconnected, :tcp_no_response})
      {:stop, :normal, state}
    else
      case :gen_tcp.send(state.socket, Frame.encode(frame)) do
        :ok ->
          {:noreply, %{state | sent: state.sent + 1}}

        {:error, reason} ->
          Logger.warning("TCP write failed: #{inspect(reason)}")
          Transport.notify(state.owner, {:disconnected, {:tcp_write_failed, reason}})
          {:stop, :normal, state}
      end
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {frames, frame_state} = Frame.decode(state.frame, data)
    Enum.each(frames, &Transport.notify(state.owner, {:frame, &1}))
    :inet.setopts(socket, active: :once)
    {:noreply, %{state | frame: frame_state, received: state.received + length(frames)}}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.debug("TCP server closed the connection")
    Transport.notify(state.owner, {:disconnected, :tcp_disconnect})
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("TCP error: #{inspect(reason)}")
    Transport.notify(state.owner, {:disconnected, {:tcp_error, reason}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{socket: socket}) when socket != nil, do: :gen_tcp.close(socket)
  def terminate(_reason, _state), do: :ok

  defp to_host(host) when is_binary(host), do: String.to_charlist(host)
  defp to_host(host), do: host
end
