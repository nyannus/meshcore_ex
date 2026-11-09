# Channels

## Sending to a channel

```elixir
{:ok, _} = Meshcore.Commands.send_chan_msg(mc, 0, "Hello channel 0")
```

Channel messages are not acknowledged; `{:ok, %{type: :ok}}` means the radio accepted it.

## Receiving, with path information

Each channel message carries the channel index and a `path_len`. To also learn the *route*,
RSSI and SNR of the packet it came from, tell the client to decode the RF log, and load the
channel secrets (they arrive in `:channel_info` events):

```elixir
{:ok, mc} = Meshcore.create_ble(adapter: MyApp.BleAdapter, address: "f1x")
Meshcore.set_decrypt_channel_logs(mc, true)
{:ok, _} = Meshcore.Commands.get_channel(mc, 0)         # teaches the client the secret
{:ok, _} = Meshcore.subscribe(mc, :channel_msg_recv)
:ok = Meshcore.start_auto_message_fetching(mc)

receive do
  {:meshcore, _, %Meshcore.Event{payload: p}} ->
    IO.inspect(Map.take(p, [:text, :path, :rssi, :snr, :recv_time, :attempt]))
end
```

(`chan_recv_with_path`). The correlation works through a hash of timestamp and text, so
`:path`, `:rssi` etc. are present only if the matching RF packet was seen first.

## Managing channels (`serial_channel_manager`)

```elixir
defmodule Channels do
  def list(mc, max \\ 8) do
    for idx <- 0..(max - 1) do
      case Meshcore.Commands.get_channel(mc, idx) do
        {:ok, %{payload: %{channel_name: ""}}} -> {idx, :empty}
        {:ok, %{payload: p}} -> {idx, p.channel_name, Base.encode16(p.channel_secret, case: :lower)}
        {:error, e} -> {idx, {:error, e.payload}}
      end
    end
  end

  # secret is derived from the name for "#hashtag" channels or when omitted
  def set(mc, idx, name, secret \\ nil),
    do: Meshcore.Commands.set_channel(mc, idx, name, secret)
end

Channels.set(mc, 1, "#ping")                                  # public hashtag channel
Channels.set(mc, 2, "Private", :crypto.strong_rand_bytes(16)) # explicit 16-byte secret
Channels.list(mc)
```

`set_channel/4` raises `ArgumentError` if an explicit secret is not exactly 16 bytes.

## Binary channel data

Firmware 1.15+ supports typed binary datagrams:

```elixir
Meshcore.Commands.send_channel_data(mc, 1, 0xFFFF, <<1, 2, 3>>)
{:ok, _} = Meshcore.subscribe(mc, :channel_data_recv, attribute_filters: %{data_type: 0xFFFF})
```

`data_type` is `0x0001..0xFFFF` (`0xFFFF` is the developer namespace), payload ≤ 163 bytes.
Pass `path:` / `path_hash_mode:` to avoid flooding.

## Flood scopes (regions)

```elixir
Meshcore.Commands.set_flood_scope(mc, "my-region")   # hashtag name, key = sha256("#my-region")[0,16]
Meshcore.Commands.set_flood_scope(mc, "*")           # force unscoped
Meshcore.Commands.set_flood_scope(mc, nil)           # reset
Meshcore.Commands.set_flood_scope(mc, {:key, key16}) # raw key

Meshcore.Commands.set_default_flood_scope(mc, "my-region")
{:ok, %{payload: p}} = Meshcore.Commands.get_default_flood_scope(mc)
```
