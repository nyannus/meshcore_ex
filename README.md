# Meshcore

[![Hex.pm](https://img.shields.io/hexpm/v/meshcore.svg)](https://hex.pm/packages/meshcore)
[![Docs](https://img.shields.io/badge/hexdocs-meshcore-blue.svg)](https://hexdocs.pm/meshcore)

Elixir client for [MeshCore](https://meshcore.io) companion radios over **serial**,
**TCP** and **BLE** – a port of the Python library
[`meshcore_py`](https://github.com/fdlamotte/meshcore_py) with the same feature set
and the same function names, built the OTP way: a supervised session process per
radio, process-message events, timeouts everywhere and automatic reconnects.

* every command of the Python library (device, contacts, messaging, channels,
  repeater logins, status/telemetry/ACL/neighbour requests, tracing, signing,
  flood scopes, node discovery …)
* all push notifications decoded into `%Meshcore.Event{}` structs, including raw
  RF log decoding and optional channel decryption
* `{:ok, event} | {:error, event}` results, millisecond timeouts, no hangs
* auto-reconnect with exponential backoff, connection events
* pluggable transports (`Meshcore.Transport` behaviour); BLE through an adapter

## Installation

```elixir
def deps do
  [
    {:meshcore, "~> 0.1.0"},
    # only needed for serial connections:
    {:circuits_uart, "~> 1.5"}
  ]
end
```

## Quick start

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
# or: Meshcore.create_tcp("192.168.1.100", 5000)

{:ok, %{payload: contacts}} = Meshcore.Commands.get_contacts(mc)
{_key, contact} = Enum.at(contacts, 0)

case Meshcore.Commands.send_msg(mc, contact, "Hello from Elixir!") do
  {:ok, sent} -> IO.inspect(sent.payload.expected_ack, label: "waiting for ack")
  {:error, event} -> IO.inspect(event.payload, label: "failed")
end

# events are plain messages
{:ok, _sub} = Meshcore.subscribe(mc, :contact_msg_recv)
:ok = Meshcore.start_auto_message_fetching(mc)

receive do
  {:meshcore, _ref, %Meshcore.Event{payload: %{text: text}}} -> IO.puts(text)
end

Meshcore.disconnect(mc)
```

In a supervision tree:

```elixir
children = [
  {Meshcore,
   name: MyApp.Radio,
   transport: {Meshcore.Transport.TCP, host: "mchome", port: 5000},
   auto_reconnect: true}
]
```

## Documentation

Full documentation, including guides translating every Python example, is on
[HexDocs](https://hexdocs.pm/meshcore). Coming from Python? Start with
*Migrating from Python*.

## Status

The wire protocol decoding is covered by unit tests built from the reference
implementation's behaviour, and the session layer by tests against a scripted
fake device. The serial and BLE transports have **not** been exercised against
real hardware yet – reports welcome.

## License

MIT. Protocol knowledge and behaviour follow
[meshcore_py](https://github.com/fdlamotte/meshcore_py) (MIT).
