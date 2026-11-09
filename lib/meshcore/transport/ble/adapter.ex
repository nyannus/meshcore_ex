defmodule Meshcore.Transport.BLE.Adapter do
  @moduledoc """
  Behaviour for the platform-specific half of the BLE transport.

  Implement it on top of whatever BLE stack you have (BlueZ over D-Bus, a
  `Port` talking to a helper such as `bleak`, a Rustler NIF around `btleplug`,
  Nerves' `blue_heron`, …) and pass the module as `:adapter` to
  `Meshcore.create_ble/1`.

  ## Contract

  `connect/2` receives the pid of the `Meshcore.Transport.BLE` process and the
  options listed below. After a successful connect the adapter must:

    * subscribe to notifications on the TX characteristic and forward each
      notification payload as `send(transport, {:ble_data, binary})`;
    * send `send(transport, {:ble_disconnected, reason})` when the link drops.

  Each notification is **one complete protocol frame** – BLE needs no extra
  framing.

  Options passed to `connect/2`: `:address` (may be `nil`), `:name_prefix`
  (`"MeshCore"`; when no usable address is given, scan for a device whose
  advertised name starts with it), `:service_uuid`, `:rx_char_uuid`,
  `:tx_char_uuid`, plus everything from the transport's `:adapter_opts`.
  """

  @typedoc "Opaque adapter state/handle, passed back to the other callbacks."
  @type handle :: term()

  @callback connect(transport :: pid(), opts :: keyword()) ::
              {:ok, handle(), address :: String.t()} | {:error, term()}

  @doc "Writes one frame to the RX characteristic (with response)."
  @callback write(handle(), frame :: binary()) :: :ok | {:error, term()}

  @doc "Pairs with the device using `pin`."
  @callback pair(handle(), pin :: String.t()) :: :ok | {:error, term()}

  @doc "Disconnects, best effort."
  @callback disconnect(handle()) :: :ok
end
