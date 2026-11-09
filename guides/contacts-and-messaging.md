# Contacts & messaging

## Contacts

```elixir
{:ok, %{payload: contacts}} = Meshcore.Commands.get_contacts(mc)
for {key, c} <- contacts, do: IO.puts("- #{c.adv_name} (#{key})")
```

`get_contacts/2` keeps waiting as long as contacts keep arriving (the `:timeout`, default 5 s, is
the tolerated *silence*), so big lists are fine. `lastmod:` fetches only what changed since.

The connection mirrors the list, so helpers are available without asking the radio again:

```elixir
Meshcore.ensure_contacts(mc)                       # fetch only if empty
Meshcore.get_contact_by_name(mc, "Bob's Radio")    # case-insensitive
Meshcore.get_contact_by_key_prefix(mc, "a1b2c3")
```

A contact is a map:

```elixir
%{public_key: "…64 hex…", type: 1, flags: 0, adv_name: "Alice",
  out_path: "aabb", out_path_len: 2, out_path_hash_mode: 0,   # out_path_len -1 = flood
  last_advert: 1_700_000_000, adv_lat: 48.1, adv_lon: 11.5, lastmod: …}
```

Management:

```elixir
Meshcore.Commands.add_contact(mc, contact)
Meshcore.Commands.remove_contact(mc, contact)
Meshcore.Commands.reset_path(mc, contact)                  # back to flooding
Meshcore.Commands.change_contact_path(mc, contact, "aabbcc")        # device's hash mode
Meshcore.Commands.change_contact_path(mc, contact, "aabbcc:1")      # 2-byte hashes
Meshcore.Commands.change_contact_flags(mc, contact, 1)
Meshcore.Commands.share_contact(mc, contact)
{:ok, %{payload: %{uri: uri}}} = Meshcore.Commands.export_contact(mc, contact)
Meshcore.Commands.export_contact(mc)                       # this node's own card
Meshcore.Commands.get_advert_path(mc, contact)
```

### Destinations

Anywhere a *destination* is expected you may pass a contact map, a hex public key, or the raw
key bytes. A binary made only of hex digits and long enough (≥ 12 characters for a prefix,
64 for a full key) is read as hex, everything else as raw bytes.

### Manual-add mode

When the radio doesn't auto-add contacts, adverts end up in `Meshcore.pending_contacts/1`:

```elixir
for {key, c} <- Meshcore.pending_contacts(mc) do
  IO.puts("new: #{c.adv_name}")
  contact = Meshcore.pop_pending_contact(mc, key)
  Meshcore.Commands.add_contact(mc, contact)
end
```

## Direct messages

```elixir
{:ok, sent} = Meshcore.Commands.send_msg(mc, contact, "Hello!")
sent.payload   #=> %{type: 0 (direct) | 1 (flood), expected_ack: <<…4 bytes>>, suggested_timeout: 3800}
```

`send_msg/4` returns as soon as the radio queued the message. Delivery is confirmed by an
`:ack` event whose `code` equals the hex of `expected_ack`:

```elixir
code = Base.encode16(sent.payload.expected_ack, case: :lower)

case Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: code}, timeout: 30_000) do
  {:ok, _} -> IO.puts("✅ delivered")
  {:error, :timeout} -> IO.puts("⚠️ no ack")
end
```

### Send, retry, fall back to flooding

```elixir
case Meshcore.Commands.send_msg_with_retry(mc, contact, "Hello!", max_attempts: 3) do
  {:ok, sent} -> IO.puts("acknowledged: #{inspect(sent.payload.expected_ack)}")
  {:error, :not_acknowledged} -> IO.puts("gave up")
end
```

After `flood_after` (default 2) silent attempts the stored path is reset so the next attempt
floods. A late ack of an *earlier* attempt still counts. Per-attempt wait defaults to the
radio's `suggested_timeout × 1.2` (override with `timeout:` / `min_timeout:`, in ms).

### The `serial_msg` example

```elixir
defmodule SendAndConfirm do
  def run(port, dest_name, text) do
    {:ok, mc} = Meshcore.create_serial(port, debug: true)

    try do
      Meshcore.ensure_contacts(mc)

      case Meshcore.get_contact_by_name(mc, dest_name) do
        nil ->
          IO.puts("Contact '#{dest_name}' not found. Available:")
          for {_, c} <- Meshcore.contacts(mc), do: IO.puts("- #{c.adv_name}")

        contact ->
          IO.puts("Found #{contact.adv_name} (#{String.slice(contact.public_key, 0, 12)}…)")

          case Meshcore.Commands.send_msg(mc, contact, text) do
            {:error, event} ->
              IO.puts("⚠️ failed: #{inspect(event.payload)}")

            {:ok, sent} ->
              code = Base.encode16(sent.payload.expected_ack, case: :lower)
              IO.puts("sent, waiting for ack #{code}")

              case Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: code}, timeout: 30_000) do
                {:ok, _} -> IO.puts("✅ Message confirmed delivered!")
                {:error, :timeout} -> IO.puts("⚠️ Timed out waiting for ACK")
              end
          end
      end
    after
      Meshcore.disconnect(mc)
    end
  end
end

SendAndConfirm.run("/dev/ttyUSB0", "🦄", "hello from serial")
```

## Receiving messages

The radio queues incoming messages and announces them with `:messages_waiting`. Either pull
them yourself –

```elixir
case Meshcore.Commands.get_msg(mc) do
  {:ok, %{type: :contact_msg_recv, payload: p}} -> IO.puts("#{p.pubkey_prefix}: #{p.text}")
  {:ok, %{type: :channel_msg_recv, payload: p}} -> IO.puts("ch#{p.channel_idx}: #{p.text}")
  {:ok, %{type: :no_more_msgs}} -> :done
  {:error, _} -> :failed
end
```

– or let the library do it: `Meshcore.start_auto_message_fetching(mc)` pulls until the queue is
empty every time `:messages_waiting` arrives. The fetched messages are then delivered to your
`:contact_msg_recv` / `:channel_msg_recv` subscriptions.

Message payloads (`contact_msg_recv`): `type: "PRIV"`, `pubkey_prefix`, `text`, `txt_type`,
`sender_timestamp`, `path_len`, `path_hash_mode` (`255`/`-1` = received by flood without path),
`snr` (v3 framing), `signature` for signed messages.

## Pub/sub chat (`pubsub_example`, `serial_chat`, `ble_chat`, `tcp_chat`)

A complete little chat client for any transport:

```elixir
defmodule Chat do
  use GenServer

  def start_link(mc), do: GenServer.start_link(__MODULE__, mc, name: __MODULE__)
  def say(contact_name, text), do: GenServer.call(__MODULE__, {:say, contact_name, text})

  @impl true
  def init(mc) do
    Meshcore.ensure_contacts(mc)
    {:ok, _} = Meshcore.subscribe(mc, [:contact_msg_recv, :channel_msg_recv, :advertisement])
    :ok = Meshcore.start_auto_message_fetching(mc)
    {:ok, mc}
  end

  @impl true
  def handle_call({:say, name, text}, _from, mc) do
    reply =
      case Meshcore.get_contact_by_name(mc, name) do
        nil -> {:error, :unknown_contact}
        contact -> Meshcore.Commands.send_msg_with_retry(mc, contact, text)
      end

    {:reply, reply, mc}
  end

  @impl true
  def handle_info({:meshcore, _, %Meshcore.Event{type: :contact_msg_recv, payload: p}}, mc) do
    name =
      case Meshcore.get_contact_by_key_prefix(mc, p.pubkey_prefix) do
        nil -> p.pubkey_prefix
        c -> c.adv_name
      end

    IO.puts("[#{name}] #{p.text}")
    {:noreply, mc}
  end

  def handle_info({:meshcore, _, %Meshcore.Event{type: :channel_msg_recv, payload: p}}, mc) do
    IO.puts("[ch#{p.channel_idx}] #{p.text}")
    {:noreply, mc}
  end

  def handle_info({:meshcore, _, %Meshcore.Event{type: :advertisement}}, mc) do
    IO.puts("(advertisement)")
    {:noreply, mc}
  end
end

{:ok, mc} = Meshcore.create_tcp("192.168.1.100", 5000)
{:ok, _} = Chat.start_link(mc)
Chat.say("Alice", "hi!")
```

Use `Meshcore.create_serial/2` or `create_ble/1` instead of `create_tcp/3` for the other
transports – nothing else changes.

## Commands to remote nodes

`send_cmd/4` sends a CLI command as a text message (reply arrives like a normal message):

```elixir
Meshcore.Commands.send_cmd(mc, repeater, "ver")
{:ok, _} = Meshcore.wait_for_event(mc, :messages_waiting, timeout: 10_000)
{:ok, %{payload: p}} = Meshcore.Commands.get_msg(mc)
IO.puts(p.text)
```
