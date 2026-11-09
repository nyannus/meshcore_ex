# Repeaters & remote nodes

Everything here talks to *other* nodes through your radio: log in, ask for status, telemetry,
access lists, neighbours, owner info …

All `*_sync` functions:

* take a contact (or key) as destination,
* return `{:ok, data}` / `{:error, event}` (`reason: :timeout` when nothing came back),
* are serialised by a per-connection lock,
* accept `timeout:` and `min_timeout:` in ms – by default the wait is derived from the
  `suggested_timeout` the radio reports for the route, which accounts for hop count.

Do `Meshcore.ensure_contacts(mc)` first so the contacts exist.

## Login

```elixir
repeater = Meshcore.get_contact_by_name(mc, "My Repeater")

case Meshcore.Commands.send_login_sync(mc, repeater, "password") do
  {:ok, %{payload: p}} -> IO.puts("logged in, admin: #{p.is_admin}")
  {:error, e} -> IO.puts("login failed: #{inspect(e.payload)}")
end
```

`send_login/3` (returns at once, you wait for `:login_success` yourself) exists for parity
and logs a deprecation hint, like in Python.

## Status (`serial_repeater_status`, `tcp_login_status`)

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
Meshcore.ensure_contacts(mc)
repeater = Meshcore.get_contact_by_name(mc, "My Repeater")

{:ok, _} = Meshcore.Commands.send_login_sync(mc, repeater, "password")

case Meshcore.Commands.req_status_sync(mc, repeater) do
  {:ok, s} ->
    IO.puts("""
    Repeater status:
      Battery:           #{s.bat} mV
      Uptime:            #{s.uptime} s
      Last RSSI / SNR:   #{s.last_rssi} dBm / #{s.last_snr} dB
      Received / sent:   #{s.nb_recv} / #{s.nb_sent}
      Flood tx / rx:     #{s.sent_flood} / #{s.recv_flood}
      Direct tx / rx:    #{s.sent_direct} / #{s.recv_direct}
      Duplicates:        #{s.direct_dups} direct, #{s.flood_dups} flood
      TX queue:          #{s.tx_queue_len}
      Airtime tx / rx:   #{s.airtime} / #{s.rx_airtime} s
    """)

  {:error, _} ->
    IO.puts("Timed out waiting for status response")
end
```

`:recv_errors` is `nil` on firmware older than v1.12.

If you prefer the event style of `tcp_login_status`:

```elixir
{:ok, _} = Meshcore.subscribe(mc, [:login_success, :login_failed, :status_response])
{:ok, _} = Meshcore.Commands.send_login(mc, repeater, "password")
Meshcore.wait_for_event(mc, :login_success,
  attribute_filters: %{pubkey_prefix: String.slice(repeater.public_key, 0, 12)}, timeout: 10_000)

{:ok, _} = Meshcore.Commands.send_statusreq(mc, repeater)
Meshcore.wait_for_event(mc, :status_response, timeout: 5_000)
```

## Telemetry (`serial_repeater_telemetry`)

```elixir
{:ok, lpp} = Meshcore.Commands.req_telemetry_sync(mc, repeater)

for %{channel: ch, type: type, value: value} <- lpp do
  IO.puts("ch#{ch} #{type}: #{inspect(value)}")
end
#=> ch1 temperature: 21.5
#=> ch1 voltage: 4.02
#=> ch2 gps: %{latitude: 48.1, longitude: 11.5, altitude: 512.0}
```

Min/max/average over a time window:

```elixir
now = System.os_time(:second)
{:ok, mma} = Meshcore.Commands.req_mma_sync(mc, repeater, now - 3600, now)
#=> [%{channel: 1, type: "temperature", min: 18.0, max: 24.5, avg: 21.2}]
```

Your own node's telemetry: `Meshcore.Commands.get_self_telemetry(mc)`.

## Access control list

```elixir
{:ok, acl} = Meshcore.Commands.req_acl_sync(mc, repeater)
#=> [%{key: "a1b2c3d4e5f6", perm: 3}, …]
```

## Neighbours

```elixir
{:ok, res} = Meshcore.Commands.req_neighbours_sync(mc, repeater, count: 20, pubkey_prefix_length: 4)
res.neighbours   #=> [%{pubkey: "a1b2c3d4", secs_ago: 120, snr: 6.5}, …]

# all of them, paging automatically:
{:ok, all} = Meshcore.Commands.fetch_all_neighbours(mc, repeater)
all.results_count == all.neighbours_count   # false if a later page kept failing
```

## Anonymous requests

These work for nodes that are **not** in your contacts:

```elixir
{:ok, regions} = Meshcore.Commands.req_regions_sync(mc, "a1b2c3…64 hex…")
{:ok, %{name: name, owner: owner}} = Meshcore.Commands.req_owner_sync(mc, contact)
{:ok, basic} = Meshcore.Commands.req_basic_sync(mc, contact)   # the node's clock
```

For contacts currently reached by flood, the client temporarily pins a zero-hop path (the
servers only answer these requests over direct routes) and resets it afterwards.

## Path discovery

```elixir
{:ok, %{payload: p}} = Meshcore.Commands.send_path_discovery_sync(mc, contact)
p.out_path   #=> "aabbcc"   (hex, `out_path_len` hops of `out_path_hash_len` bytes)
p.in_path
```

## Async variants

`req_*_async` return the `:msg_sent` event; the answer comes as an event filtered by `tag`:

```elixir
{:ok, sent} = Meshcore.Commands.req_neighbours_async(mc, repeater)
tag = Base.encode16(sent.payload.expected_ack, case: :lower)
Meshcore.wait_for_event(mc, :neighbours_response, attribute_filters: %{tag: tag}, timeout: 30_000)
```

> Note: with the async API you register the wait *after* the request returned. A very fast
> answer can be missed – prefer the `*_sync` functions, which cannot lose it.

## Node discovery

```elixir
{:ok, %{payload: %{tag: tag}}} = Meshcore.Commands.send_node_discover_req(mc, 0b0000_0100)
# repeaters/sensors answer with :discover_response events carrying the tag:
{:ok, _} = Meshcore.subscribe(mc, :discover_response, attribute_filters: %{tag: Base.encode16(<<tag::little-32>>, case: :lower)})
```
