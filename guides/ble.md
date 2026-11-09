# BLE

There is no mature cross-platform BLE stack on the BEAM, so `Meshcore.Transport.BLE` contains
the MeshCore-specific behaviour and delegates the radio work to an **adapter** you provide:

| handled by the transport | handled by your adapter |
| --- | --- |
| serialised writes (overlapping GATT writes kill the link) | scanning / connecting |
| a hard write timeout – a stalled write tears the link down so the reconnect logic takes over | subscribing to TX notifications |
| optional PIN pairing; a failed pairing disconnects cleanly | writing to the RX characteristic |
| nothing needs extra framing: one notification = one frame | pairing |

## Connecting

```elixir
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter)                       # scan for MeshCore*
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "12:34:56:78:90:AB")
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "T1000", pin: "123456")
```

`address:` may also be (part of) the advertised name. Under a supervisor:

```elixir
{Meshcore,
 name: MyApp.Radio,
 transport: {Meshcore.Transport.BLE, adapter: MyApp.BleAdapter, address: "T1000", pin: "123456"},
 auto_reconnect: true}
```

## Writing an adapter

Implement `Meshcore.Transport.BLE.Adapter`:

```elixir
defmodule MyApp.BleAdapter do
  @behaviour Meshcore.Transport.BLE.Adapter

  @impl true
  def connect(transport, opts) do
    # opts: :address (may be nil), :name_prefix ("MeshCore"), :service_uuid,
    #       :rx_char_uuid, :tx_char_uuid and your :adapter_opts
    #
    # 1. find/connect the device
    # 2. subscribe to the TX characteristic; for every notification:
    #       send(transport, {:ble_data, binary})
    # 3. on link loss:
    #       send(transport, {:ble_disconnected, reason})
    {:ok, handle, "12:34:56:78:90:AB"}
  end

  @impl true
  def write(handle, frame), do: :ok            # write to RX characteristic, with response

  @impl true
  def pair(handle, pin), do: :ok               # or {:error, reason}

  @impl true
  def disconnect(handle), do: :ok
end
```

A practical approach is a `Port` talking to a tiny helper in another language
(for example [`bleak`](https://github.com/hbldh/bleak) in Python, or `btleplug` in Rust). The
adapter then just relays notifications to the transport process and forwards writes.

The UUIDs are available as `Meshcore.Transport.BLE.uart_service_uuid/0`,
`uart_rx_char_uuid/0` and `uart_tx_char_uuid/0`.

## PIN pairing

```elixir
# once, to configure the PIN on the device:
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "12:34:56:78:90:AB")
Meshcore.Commands.set_devicepin(mc, 123_456)
Meshcore.disconnect(mc)

# afterwards:
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "12:34:56:78:90:AB", pin: "123456")
```

Pairing behaviour differs by platform (Linux/Windows: explicit; macOS: usually handled by the
system UI) – that part is up to your adapter. If `pair/2` returns an error the connection
fails with `{:error, {:connect_failed, {:pairing_failed, reason}}}`.

Features that need an authenticated link (e.g. [private key export](signing-and-keys.md)) should
be used with `pin:`.

## Testing without hardware

The adapter boundary makes the transport easy to test: write a module that sends canned
`{:ble_data, frame}` messages (see `test/meshcore/transport_test.exs` in the repository).
