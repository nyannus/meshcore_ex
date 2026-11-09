# Getting started

## Install

```elixir
# mix.exs
{:meshcore, "~> 0.1.0"},
{:circuits_uart, "~> 1.5"}   # only for serial
```

For one-off scripts use `Mix.install/1`:

```elixir
Mix.install([{:meshcore, "~> 0.1.0"}, {:circuits_uart, "~> 1.5"}])
```

## Your first connection

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
Meshcore.self_info(mc)
#=> %{name: "MyNode", public_key: "ab12…", radio_freq: 869.525, …}
Meshcore.disconnect(mc)
```

`mc` is the pid of a `Meshcore.Client` – every function takes it as first argument.
`create_*` blocks until the handshake (`CMD_APP_START`) succeeded and returns
`{:ok, mc}` or `{:error, reason}`; the Python factories return `None` instead.

## Results

Every command returns an event, tagged:

```elixir
case Meshcore.Commands.send_device_query(mc) do
  {:ok, %Meshcore.Event{type: :device_info, payload: info}} ->
    IO.puts("model: #{info.model}, firmware #{info.ver}")

  {:error, %Meshcore.Event{type: :error, payload: payload}} ->
    IO.inspect(payload)
end
```

An error payload is one of

* `%{reason: :timeout}` – the device did not answer in time
* `%{reason: :not_connected}` / `%{reason: :disconnected}` – no link (any command waiting when
  the link drops fails immediately)
* `%{error_code: 2, code_string: "ERR_CODE_NOT_FOUND"}` – the firmware rejected the command

Because results are tagged tuples, `with` chains read naturally:

```elixir
with {:ok, _} <- Meshcore.Commands.set_name(mc, "Alice"),
     {:ok, _} <- Meshcore.Commands.set_tx_power(mc, 20),
     {:ok, _} <- Meshcore.Commands.send_advert(mc, true) do
  :ok
end
```

## Payload conventions

Payloads are maps with **atom keys**. Compared with Python's dicts:

* keys are lower-case (`"SNR"` → `:snr`, `"fw ver"` → `:fw_ver`)
* public keys are lower-case **hex strings**; ack codes / tags in `msg_sent` are raw bytes
  (`payload.expected_ack`) while the matching `:ack` event carries the hex string
  (`attributes.code`)
* contacts are plain maps (`:public_key`, `:adv_name`, `:type`, `:out_path`, …)

## Timeouts are milliseconds

```elixir
Meshcore.set_default_timeout(mc, 30_000)
Meshcore.Commands.get_contacts(mc, timeout: 10_000)
Meshcore.wait_for_event(mc, :ack, timeout: 5_000)
```

## Next steps

* [Connecting](connecting.md) – serial, TCP, BLE, supervision, reconnects
* [Commands & events](commands-and-events.md)
* [Contacts & messaging](contacts-and-messaging.md)
