# Migrating from Python

The library mirrors `meshcore_py`; names translate mechanically.

## The five rules

1. **`mc.commands.foo(args)` → `Meshcore.Commands.foo(mc, args)`**, with the connection first.
   Optional/keyword arguments become a keyword list: `send_msg(c, "x", timestamp: 1)`.
2. **Results are tagged**: `result.type == EventType.ERROR` ⇒ `{:error, %Event{}}`; otherwise
   `{:ok, %Event{}}`. The event still has `.type`, `.payload`, `.attributes`.
3. **Timeouts are milliseconds** (`timeout=5` ⇒ `timeout: 5_000`). `0`/`None` for "derive
   from the device's suggestion" ⇒ omit the option.
4. **Dict keys are atoms**, lower-case: `payload["SNR"]` ⇒ `payload.snr`, `"fw ver"` ⇒ `:fw_ver`.
   Event types are lower-case atoms: `EventType.CONTACT_MSG_RECV` ⇒ `:contact_msg_recv`.
5. **Callbacks become messages**: `subscribe(type, async_cb, filters)` ⇒ subscribe, then handle
   `{:meshcore, ref, %Event{}}`.

## Connection

| Python | Elixir |
| --- | --- |
| `await MeshCore.create_serial(port, baud, debug=True)` | `Meshcore.create_serial(port, baudrate: baud, debug: true)` |
| `await MeshCore.create_tcp(host, port, auto_reconnect=True)` | `Meshcore.create_tcp(host, port, auto_reconnect: true)` |
| `await MeshCore.create_ble(address, pin="1234")` | `Meshcore.create_ble(adapter: A, address: addr, pin: "1234")` |
| factory returns `None` on failure | `{:error, reason}` |
| `await mc.connect()` | `Meshcore.connect(mc)` |
| `await mc.disconnect()` | `Meshcore.disconnect(mc)` (also stops the process) |
| `mc.stop()` | `Meshcore.stop(mc)` |
| `mc.is_connected` | `Meshcore.connected?(mc)` |
| `BLEConnection(...)` / `TCPConnection(...)` / `SerialConnection(...)` passed to `MeshCore(cx)` | `Meshcore.start_link(transport: {Meshcore.Transport.TCP, host: …, port: …})` |
| `default_timeout` property | `Meshcore.default_timeout/1`, `set_default_timeout/2` |
| `debug=True` / `only_error=True` | `debug: true` / `only_error: true` (affects this connection's log level only) |

## State & helpers

| Python | Elixir |
| --- | --- |
| `mc.contacts` | `Meshcore.contacts(mc)` |
| `mc.self_info` | `Meshcore.self_info(mc)` |
| `mc.time` | `Meshcore.time(mc)` |
| `mc.contacts_dirty` | `Meshcore.contacts_dirty?(mc)` |
| `mc.auto_update_contacts = True` | `Meshcore.set_auto_update_contacts(mc, true)` |
| `mc.pending_contacts` | `Meshcore.pending_contacts(mc)` |
| `mc.pop_pending_contact(key)` | `Meshcore.pop_pending_contact(mc, key)` |
| `mc.flush_pending_contacts()` | `Meshcore.flush_pending_contacts(mc)` |
| `mc.set_decrypt_channel_logs(True)` | `Meshcore.set_decrypt_channel_logs(mc, true)` |
| `mc.get_contact_by_name(n)` | `Meshcore.get_contact_by_name(mc, n)` |
| `mc.get_contact_by_key_prefix(p)` | `Meshcore.get_contact_by_key_prefix(mc, p)` |
| `await mc.ensure_contacts(follow=False)` | `Meshcore.ensure_contacts(mc, follow \\ false)` → boolean |
| `await mc.start_auto_message_fetching()` | `Meshcore.start_auto_message_fetching(mc)` |
| `await mc.stop_auto_message_fetching()` | `Meshcore.stop_auto_message_fetching(mc)` |

## Events

| Python | Elixir |
| --- | --- |
| `sub = mc.subscribe(EventType.ACK, cb, attribute_filters={"code": c})` | `{:ok, sub} = Meshcore.subscribe(mc, :ack, attribute_filters: %{code: c})` |
| `mc.subscribe(None, cb)` (all events) | `Meshcore.subscribe(mc, nil)` |
| `mc.unsubscribe(sub)` | `Meshcore.unsubscribe(sub)` |
| `await mc.wait_for_event(T, filters, timeout=5)` → event or `None` | `Meshcore.wait_for_event(mc, :t, attribute_filters: f, timeout: 5_000)` → `{:ok, event}` or `{:error, :timeout}` |
| `event.is_error()` | `Meshcore.Event.error?(event)` |

## Commands: return values that are not plain events

Python's `*_sync` helpers return a payload or `None`; the Elixir ones return `{:ok, payload}` or
`{:error, event}` (the event tells you why, e.g. `reason: :timeout`):

| Python returns | Elixir returns |
| --- | --- |
| `req_status_sync` → status dict / `None` | `{:ok, status_map}` |
| `req_telemetry_sync` → lpp list / `None` | `{:ok, lpp_list}` |
| `req_mma_sync` → list / `None` | `{:ok, list}` |
| `req_acl_sync` → list / `None` | `{:ok, list}` |
| `req_neighbours_sync`, `fetch_all_neighbours` → dict / `None` | `{:ok, map}` |
| `req_regions_sync` → str / `None` | `{:ok, string}` |
| `req_owner_sync` → `{name, owner}` / `None` | `{:ok, %{name:, owner:}}` |
| `req_basic_sync` → payload / `None` | `{:ok, payload}` |
| `send_login_sync`, `send_path_discovery_sync` → Event / `None` | `{:ok, event}` |
| `send_msg_with_retry` → Event / `None` | `{:ok, msg_sent_event}` / `{:error, :not_acknowledged}` |
| `request_factory_reset()` → token | `{:ok, token}` |
| `confirm_factory_reset(bad)` raises `ValueError` | `{:error, :invalid_token}` |
| `get_path_hash_mode()` → int | int (unchanged) |

Programmer errors (malformed destination, bad key length, payload too short …) raise
`ArgumentError` where Python raised `ValueError`.

## Argument conventions

* **Destinations** accept a contact map, a hex string or raw bytes. (Python's `bytes` vs `str`
  distinction doesn't exist for Elixir binaries; hex-looking binaries that are long enough are
  read as hex.)
* **Hex or bytes** parameters that Python lets you pass as `str` (`send_raw_packet`) take raw
  binaries or `{:hex, "…"}`.
* **Trace path**: a comma-separated hex string, or `{:raw, binary}` for Python's `bytes`.
* **Flood scope**: a string name, `"*"`, `nil`, or `{:key, binary}` for Python's raw `bytes`.
* `send_advert(flood=True)` ⇒ `send_advert(mc, true)`.
* `get_contacts(lastmod=…, timeout=…)` ⇒ `get_contacts(mc, lastmod: …, timeout: …)`.
* `sign(data, chunk_size, timeout)` ⇒ `sign(mc, data, chunk_size: …, timeout: …)`.

## Payload key differences

* `"SNR"`/`"RSSI"` ⇒ `:snr`/`:rssi`; `"SNR_in"` ⇒ `:snr_in`; `"fw ver"` ⇒ `:fw_ver`.
* `reason` strings that the library generates are atoms: `:timeout`, `:no_event_received`,
  `:not_connected`, `:disconnected`, `:invalid_frame_length`, `:path_reset_failed`,
  `:invalid_timestamp_format`, `:invalid_path_format`, `:data_too_large`, …
* `DISABLED` carries `reason: :private_key_export_disabled`.
* Contact `type`, flags, `out_path_len` (-1 = flood) etc. are unchanged.
* Telemetry LPP entries are `%{channel:, type:, value:}`; numeric values with scale 1 are
  integers (Python: floats).

## Deliberate differences

* **Exponential backoff** (1/2/4/8 s) for reconnects, as the Python README documents (the Python
  code actually sleeps a flat second).
* `start_auto_message_fetching` drains the whole queue immediately instead of fetching a single
  message.
* Pending commands fail at once on disconnect instead of waiting for their timeout.
* Concurrent commands are answered in send order rather than "everyone gets the first match".
* Sync requests can't lose a fast response (see [Fault tolerance](fault-tolerance.md)).
* Contact updates (`reset_path`, `update_contact`, …) update the client's mirrored list only
  after the device confirmed them.
* Over-long contact names are truncated to 32 bytes instead of producing a malformed frame.
* `Meshcore.disconnect/1` ends the connection process (it is the Python `disconnect()` that
  cleans up everything); to connect again start a new connection.

## A complete translation

Python:

```python
mc = await MeshCore.create_serial("/dev/ttyUSB0")
await mc.ensure_contacts()
contact = mc.get_contact_by_name("Alice")
result = await mc.commands.send_msg(contact, "hi")
if result.type == EventType.ERROR:
    print(result.payload)
else:
    ack = await mc.wait_for_event(
        EventType.ACK,
        attribute_filters={"code": result.payload["expected_ack"].hex()},
        timeout=30,
    )
await mc.disconnect()
```

Elixir:

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
Meshcore.ensure_contacts(mc)
contact = Meshcore.get_contact_by_name(mc, "Alice")

case Meshcore.Commands.send_msg(mc, contact, "hi") do
  {:error, event} ->
    IO.inspect(event.payload)

  {:ok, event} ->
    code = Base.encode16(event.payload.expected_ack, case: :lower)
    Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: code}, timeout: 30_000)
end

Meshcore.disconnect(mc)
```

## Example index

| Python example | Where |
| --- | --- |
| `serial_infos`, `tcp_mchome_infos` | [Connecting](connecting.md) |
| `tcp_mchome_contacts`, `tcp_mchome_readmsgs`, `tcp_mchome_msg` | [Connecting](connecting.md) |
| `serial_msg`, `serial_contacts`, `ble_t1000_msg*`, `serial_chat`, `ble_chat`, `tcp_chat`, `pubsub_example` | [Contacts & messaging](contacts-and-messaging.md) |
| `ble_t1000_chan_msg`, `chan_recv_with_path`, `serial_channel_manager` | [Channels](channels.md) |
| `serial_repeater_status`, `serial_repeater_telemetry`, `tcp_login_status` | [Repeaters](repeaters.md) |
| `ble_stats`, `ble_t1000_infos`, `ble_t1000_custom_vars`, `ble_t1000_set_cv`, `mepo_mc_gps` | [Device management](device-management.md) |
| `ble_sign_example`, `ble_private_key_export` | [Signing & keys](signing-and-keys.md) |
| `rf_packet_monitor`, `serial_trace` | [Monitoring & tracing](monitoring-and-tracing.md) |
| `serial_pingbot`, `serial_rss_bot`, `serial_meshcore_ollama` | [Bots](bots.md) |
| `serial_battery_monitor`, `connection_events_example` | [Commands & events](commands-and-events.md), [Connecting](connecting.md) |
| `ble_pin_pairing_example` | [BLE](ble.md) |
