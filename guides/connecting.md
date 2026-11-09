# Connecting

Three transports ship with the library. All of them end up in the same
`Meshcore.Client` process; pick one with the matching `create_*` function.

## Serial

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0", baudrate: 115_200, debug: true)
```

Requires the optional `:circuits_uart` dependency. If the radio does not answer, the
connection is retried once with the DTR line inverted (some boards – e.g. Heltec V2 – reset
when DTR is asserted). Other options: `:dtr` (`true`), `:rts` (`false`), `:cx_delay` (ms to
settle after opening, `100`).

Serial example – device infos:

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/tty.usbserial-583A0069501")
IO.inspect(Meshcore.self_info(mc))
Meshcore.disconnect(mc)
```

## TCP

```elixir
{:ok, mc} = Meshcore.create_tcp("192.168.1.100", 5000)
```

The TCP transport also notices dead links: five requests in a row without any frame coming
back end the connection with the reason `"tcp_no_response"` (so the reconnect logic can kick
in).

Reading messages from a TCP companion (`tcp_mchome_readmsgs`):

```elixir
{:ok, mc} = Meshcore.create_tcp("mchome", 5000)
{:ok, _} = Meshcore.subscribe(mc, [:contact_msg_recv, :channel_msg_recv])
:ok = Meshcore.start_auto_message_fetching(mc)

Stream.repeatedly(fn ->
  receive do
    {:meshcore, _, %Meshcore.Event{payload: p}} -> p
  end
end)
|> Enum.each(&IO.inspect/1)
```

Listing contacts and infos (`tcp_mchome_contacts`, `tcp_mchome_infos`):

```elixir
{:ok, mc} = Meshcore.create_tcp("mchome", 5000)
IO.inspect(Meshcore.self_info(mc))

Meshcore.ensure_contacts(mc)
for {_key, c} <- Meshcore.contacts(mc), do: IO.puts("#{c.adv_name}  #{c.public_key}")
```

Sending a message and waiting for the ack (`tcp_mchome_msg`):

```elixir
{:ok, mc} = Meshcore.create_tcp("mchome", 5000)
Meshcore.ensure_contacts(mc)

with %{} = contact <- Meshcore.get_contact_by_name(mc, "t114_fdl"),
     {:ok, sent} <- Meshcore.Commands.send_msg(mc, contact, "Hello World") do
  code = Base.encode16(sent.payload.expected_ack, case: :lower)
  IO.inspect(Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: code}, timeout: 5_000))
end
```

## BLE

BLE needs a platform adapter – see the [BLE guide](ble.md).

## Under a supervisor

`create_*` starts the connection under `Meshcore.ConnectionSupervisor` with `restart: :temporary`.
For a long-running application put the connection in *your* tree instead:

```elixir
children = [
  {Meshcore,
   name: MyApp.Radio,
   transport: {Meshcore.Transport.Serial, port: "/dev/ttyUSB0"},
   auto_reconnect: true,
   max_reconnect_attempts: 10}
]
```

`Meshcore.start_link/1` never blocks on the device and never fails because the radio is
unreachable: it connects in the background and, with `auto_reconnect`, keeps trying. Wait for
the handshake with `Meshcore.connect/1` if you need to.

The registered name works as `mc` everywhere: `Meshcore.Commands.get_bat(MyApp.Radio)`.

## Auto-reconnect and connection events

```elixir
{:ok, mc} =
  Meshcore.create_tcp("192.168.1.100", 5000, auto_reconnect: true, max_reconnect_attempts: 5)

{:ok, _} = Meshcore.subscribe(mc, [:connected, :disconnected])

receive do
  {:meshcore, _, %Meshcore.Event{type: :connected, payload: %{reconnected: true}}} ->
    IO.puts("reconnected!")

  {:meshcore, _, %Meshcore.Event{type: :disconnected, payload: %{max_attempts_exceeded: true}}} ->
    IO.puts("giving up")
end

Meshcore.connected?(mc)
```

* the delay between attempts doubles: 1 s, 2 s, 4 s, 8 s (capped)
* after every reconnect the `CMD_APP_START` handshake is repeated *before* the
  `:connected` event (`reconnected: true`) is emitted, so reacting to it is safe
* commands waiting when the link drops fail at once with `reason: :disconnected`
* `:disconnected` payloads: `%{reason: "manual_disconnect"}`, `%{reason: "tcp_disconnect"}`,
  `%{reason: "reconnect_failed", max_attempts_exceeded: true}` …

A full monitor script (`connection_events_example`):

```elixir
{:ok, mc} = Meshcore.create_tcp("192.168.1.100", 5000, auto_reconnect: true)
{:ok, _} = Meshcore.subscribe(mc, [:connected, :disconnected])

loop = fn loop ->
  receive do
    {:meshcore, _, %Meshcore.Event{type: :connected, payload: p}} ->
      IO.puts("Connected: #{inspect(p)}")

    {:meshcore, _, %Meshcore.Event{type: :disconnected, payload: p}} ->
      IO.puts("Disconnected: #{p.reason}")
  after
    10_000 ->
      if Meshcore.connected?(mc) do
        IO.inspect(Meshcore.Commands.get_bat(mc), label: "battery")
      end
  end

  loop.(loop)
end

loop.(loop)
```
