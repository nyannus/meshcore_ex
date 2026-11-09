# Commands & events

## Two ways to talk to a radio

**Command style** – ask, get the answer back:

```elixir
{:ok, %{payload: %{level: mv}}} = Meshcore.Commands.get_bat(mc)
```

**Event style** – subscribe and react:

```elixir
{:ok, sub} = Meshcore.subscribe(mc, :contact_msg_recv)

receive do
  {:meshcore, ref, %Meshcore.Event{payload: payload}} when ref == sub.ref ->
    IO.puts("#{payload.pubkey_prefix}: #{payload.text}")
end
```

Events are delivered as `{:meshcore, subscription_ref, %Meshcore.Event{}}` to the subscribing
process (or `pid:`). Inside a `GenServer`:

```elixir
def init(_) do
  {:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
  {:ok, _} = Meshcore.subscribe(mc, [:contact_msg_recv, :channel_msg_recv])
  :ok = Meshcore.start_auto_message_fetching(mc)
  {:ok, %{mc: mc}}
end

def handle_info({:meshcore, _ref, %Meshcore.Event{type: type, payload: p}}, state) do
  Logger.info("#{type}: #{inspect(p)}")
  {:noreply, state}
end
```

Subscriptions are bound to the subscriber: when it dies the subscription disappears. A
slow or crashing subscriber can never block or crash the connection – it only owns its mailbox.

## Filtering by attributes

Every event carries `attributes` you can filter on:

```elixir
# only channel 1
Meshcore.subscribe(mc, :channel_msg_recv, attribute_filters: %{channel_idx: 1})

# only messages from one contact
Meshcore.subscribe(mc, :contact_msg_recv,
  attribute_filters: %{pubkey_prefix: String.slice(contact.public_key, 0, 12)})

# wait for the ack of a specific message
Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: expected_ack_hex}, timeout: 30_000)
```

| Event | Attributes |
| --- | --- |
| `:contact_msg_recv` | `pubkey_prefix`, `txt_type` |
| `:channel_msg_recv` | `channel_idx`, `txt_type` |
| `:channel_data_recv` | `channel_idx`, `data_type` |
| `:msg_sent` | `type`, `expected_ack` (hex) |
| `:ack` | `code` (hex) |
| `:contacts` | `lastmod` |
| `:advertisement`, `:path_update` | `public_key` |
| `:login_success`, `:login_failed` | `pubkey_prefix` |
| `:status_response` | `pubkey_prefix` (and `tag` for binary requests) |
| `:telemetry_response` | `pubkey_prefix`, `raw` (push) / `tag` (binary request) |
| `:trace_data` | `tag`, `auth_code` |
| `:rx_log_data` | `route_type`, `payload_type`, `path_len`, `path`, `recv_time` |
| `:path_response` | `pubkey_pre` |
| `:binary_response`, `:mma_response`, `:acl_response`, `:neighbours_response` | `tag` (and `pubkey_prefix`) |
| `:discover_response` | `node_type`, `tag`, `pubkey` |
| `:control_data` | `payload_type` |
| `:autoadd_config`, `:channel_info` | the payload itself |

Pass `nil` (or `:all`) as type to see everything – handy for debugging:

```elixir
Meshcore.subscribe(mc, nil)
```

## Waiting for one event

```elixir
case Meshcore.wait_for_event(mc, :messages_waiting, timeout: 60_000) do
  {:ok, _event} -> Meshcore.Commands.get_msg(mc)
  {:error, :timeout} -> :nothing_happened
end
```

`wait_for_event/3` also accepts a list of types and returns the first match.

## Battery monitor (`serial_battery_monitor`)

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
{:ok, _} = Meshcore.subscribe(mc, :battery)

Stream.repeatedly(fn ->
  Meshcore.Commands.get_bat(mc)

  receive do
    {:meshcore, _, %Meshcore.Event{payload: %{level: mv}}} -> IO.puts("Battery: #{mv}mV")
  after
    1_000 -> :ok
  end

  Process.sleep(10_000)
end)
|> Stream.run()
```

(Of course `get_bat/1` already returns the reading; the subscription shows the event path.)

## Reading the mirrored state

The connection keeps a copy of what the device told it:

```elixir
Meshcore.self_info(mc)          # from the handshake
Meshcore.contacts(mc)           # %{public_key_hex => contact}
Meshcore.contacts_dirty?(mc)    # an advert/path update arrived since the last refresh
Meshcore.time(mc)               # last :current_time
Meshcore.pending_contacts(mc)   # adverts waiting to be added (manual-add mode)
Meshcore.connected?(mc)
```

`Meshcore.set_auto_update_contacts(mc, true)` makes the client re-fetch contacts by itself when
adverts or path updates make them stale.

## Concurrency notes

* Commands can be issued from any process, concurrently. Responses are matched first-come,
  first-served in send order, which is exactly how the firmware serialises them.
* "Mesh requests" (`send_login_sync`, `req_*_sync`, `send_path_discovery_sync`) additionally take
  a per-connection FIFO lock so only one is in flight – the radio can't do more anyway. The lock is
  released if the caller crashes.
* Sync requests register their response handler *before* the radio can answer, so a reply that
  arrives immediately after the acknowledgement is never lost (Python can lose it).
