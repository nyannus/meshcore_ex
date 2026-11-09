defmodule Meshcore.Commands.ControlData do
  @moduledoc """
  Control-data commands, used for node discovery.
  """

  require Logger
  import Meshcore.Util
  import Meshcore.Commands.Base

  alias Meshcore.{Event, Packets}

  @type mc :: GenServer.server()
  @type result :: {:ok, Event.t()} | {:error, Event.t()}

  @doc "Sends raw control data of the given control type byte."
  @spec send_control_data(mc(), 0..255, binary()) :: result()
  def send_control_data(mc, control_type, payload),
    do: send_ok(mc, <<Packets.command(:send_control_data), control_type>> <> payload)

  @doc """
  Broadcasts a node discovery request. Responses arrive as `:discover_response`
  events whose `tag` attribute equals the `:tag` in the returned payload.

  Options: `:prefix_only` (default `true`), `:tag` (default random), `:since`.
  """
  @spec send_node_discover_req(mc(), 0..255, keyword()) :: result()
  def send_node_discover_req(mc, filter, opts \\ []) do
    tag = opts[:tag] || random_u32()
    prefix_only = Keyword.get(opts, :prefix_only, true)

    data = <<filter>> <> u(tag, 4)
    data = if opts[:since], do: data <> u(opts[:since], 4), else: data
    Logger.debug("sending node discover req #{hex(data)}")

    flags = if prefix_only, do: 1, else: 0

    case send_control_data(mc, Bitwise.bor(Packets.control_type(:node_discover_req), flags), data) do
      {:ok, event} -> {:ok, %{event | payload: Map.put(event.payload, :tag, tag)}}
      error -> error
    end
  end
end
