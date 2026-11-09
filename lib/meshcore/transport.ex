defmodule Meshcore.Transport do
  @moduledoc """
  Behaviour implemented by byte transports (serial, TCP, BLE, or your own).

  A transport is a process started by `Meshcore.Client` with the option
  `:owner` set to the client's pid. It talks to its owner exclusively through
  messages:

    * `{:meshcore_transport, pid, {:connected, info}}` – the link is up; `info`
      identifies the connection (host, port, address…) and ends up in the
      `:connected` event payload.
    * `{:meshcore_transport, pid, {:frame, binary}}` – one complete companion
      protocol frame (already de-framed).
    * `{:meshcore_transport, pid, {:disconnected, reason}}` – the link was lost
      or could not be established. The transport should stop after sending it.

  Connecting must happen **asynchronously** (e.g. in `c:GenServer.handle_continue/2`)
  so that `start_link/1` returns immediately; a failed connect is reported as
  `{:disconnected, {:connect_failed, reason}}`.

  A transport is linked to its owner: if the owner dies the transport dies with
  it, and if the transport crashes the owner treats it as a lost connection
  and (optionally) reconnects with a fresh process.
  """

  @doc "Starts the transport. `opts` always contains `:owner`."
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Sends one protocol frame (the transport adds any wire framing).

  Must not block the caller: implement it as a cast. Write failures are
  reported to the owner as a `{:disconnected, reason}` message.
  """
  @callback send_frame(transport :: pid(), frame :: binary()) :: :ok

  @doc "Closes the link and stops the transport process."
  @callback close(transport :: pid()) :: :ok

  @typedoc "A transport module plus its start options."
  @type spec :: {module(), keyword()}

  @doc false
  @spec notify(pid(), term()) :: :ok
  def notify(owner, message) do
    send(owner, {:meshcore_transport, self(), message})
    :ok
  end
end
