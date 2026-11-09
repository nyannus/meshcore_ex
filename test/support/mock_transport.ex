defmodule Meshcore.Test.MockTransport do
  @moduledoc false
  # A scriptable fake device.
  #
  # Options: `:test_pid` (receives `{:mock_transport, pid}` on start and
  # `{:mock_sent, frame}` for every frame the client sends), `:responder`
  # (`fn frame -> [response_frame]`, replies are pushed back automatically),
  # `:connect` (`:ok` | `{:error, reason}`).
  @behaviour Meshcore.Transport
  use GenServer

  alias Meshcore.Transport

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

  @doc "Pushes a frame from the 'device' to the client."
  def push(pid, frame), do: GenServer.cast(pid, {:push, frame})

  @doc "Simulates a lost link."
  def drop(pid, reason \\ :mock_drop), do: GenServer.cast(pid, {:drop, reason})

  @impl GenServer
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      test_pid: opts[:test_pid],
      responder: opts[:responder],
      connect: Keyword.get(opts, :connect, :ok)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, %{connect: :ok} = state) do
    if state.test_pid, do: send(state.test_pid, {:mock_transport, self()})
    Transport.notify(state.owner, {:connected, "mock"})
    {:noreply, state}
  end

  def handle_continue(:connect, %{connect: {:error, reason}} = state) do
    Transport.notify(state.owner, {:disconnected, {:connect_failed, reason}})
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_cast({:send, frame}, state) do
    if state.test_pid, do: send(state.test_pid, {:mock_sent, frame})

    if state.responder do
      state.responder.(frame)
      |> List.wrap()
      |> Enum.each(&Transport.notify(state.owner, {:frame, &1}))
    end

    {:noreply, state}
  end

  def handle_cast({:push, frame}, state) do
    Transport.notify(state.owner, {:frame, frame})
    {:noreply, state}
  end

  def handle_cast({:drop, reason}, state) do
    Transport.notify(state.owner, {:disconnected, reason})
    {:stop, :normal, state}
  end
end
