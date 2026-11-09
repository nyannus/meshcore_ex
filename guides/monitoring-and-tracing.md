# Monitoring & tracing

## Raw RF packets (`rf_packet_monitor`)

Every packet the radio hears is reported as `:rx_log_data`. The library decodes the header,
route/payload type, path and adverts for you:

```elixir
{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
{:ok, _} = Meshcore.subscribe(mc, :rx_log_data)

Stream.repeatedly(fn ->
  receive do
    {:meshcore, _, %Meshcore.Event{payload: p}} -> p
  end
end)
|> Enum.each(fn p ->
  IO.puts("""
  RF packet  #{p[:route_typename]}/#{p[:payload_typename]}
    SNR #{p[:snr]} dB  RSSI #{p[:rssi]} dBm  #{p[:payload_length]} bytes
    path (#{p[:path_len]} hops): #{p[:path]}
    raw: #{p[:payload]}
  """)
end)
```

Useful keys: `:snr`, `:rssi`, `:recv_time`, `:header`, `:route_type(name)`, `:payload_type(name)`
(`"TEXT_MSG"`, `"ADVERT"`, `"GRP_TXT"`, `"TRACE"` …), `:path_len`, `:path_hash_size`, `:path`
(hex), `:transport_code`, `:pkt_payload` (raw bytes), `:pkt_hash`. Adverts add `:adv_name`,
`:adv_key`, `:adv_type`, `:adv_lat`, `:adv_lon`. Group-text packets add `:chan_hash`,
`:chan_name` (when the secret is known) and, with `set_decrypt_channel_logs/2`, `:message`.

Filter on attributes to focus, e.g. only adverts: `attribute_filters: %{payload_type: 4}`.

## Tracing a path (`serial_trace`)

`send_trace/2` makes a packet travel through a chain of repeaters and report the SNR at each hop.

```elixir
defmodule Trace do
  def run(mc, path) do
    Meshcore.ensure_contacts(mc)
    tag = :rand.uniform(0xFFFFFFFF)

    case Meshcore.Commands.send_trace(mc, path: path, tag: tag) do
      {:error, e} ->
        IO.puts("Failed to send trace: #{inspect(e.payload.reason)}")

      {:ok, _sent} ->
        case Meshcore.wait_for_event(mc, :trace_data, attribute_filters: %{tag: tag}, timeout: 15_000) do
          {:ok, %{payload: trace}} -> print(mc, trace)
          {:error, :timeout} -> IO.puts("No trace response received within timeout")
        end
    end
  end

  defp print(mc, trace) do
    IO.puts("Trace #{trace.tag}: #{trace.path_len} hops")

    trace
    |> Map.get(:path, [])
    |> Enum.with_index(1)
    |> Enum.each(fn
      {%{hash: hash, snr: snr}, i} ->
        IO.puts("  #{i}. #{name(mc, hash)}  SNR #{snr} dB")

      {%{snr: snr}, i} ->
        IO.puts("  #{i}. (this node)  SNR #{snr} dB")
    end)
  end

  defp name(mc, hash) do
    case Meshcore.get_contact_by_key_prefix(mc, hash) do
      nil -> "unknown (#{hash})"
      c -> c.adv_name
    end
  end
end

{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
Trace.run(mc, "23,5f,3a")        # comma separated hex hashes, 1 byte each
Trace.run(mc, "2345,5f60")       # 2-byte hashes -> flags derived automatically
Meshcore.disconnect(mc)
```

`path:` also accepts `{:raw, binary}`; `flags:` (low two bits = hash size) and `auth_code:`
can be set explicitly. A malformed path yields `{:error, %{payload: %{reason: :invalid_path_format}}}`.

## Pings and routes

`Meshcore.Commands.send_path_discovery_sync/3` (see [Repeaters](repeaters.md)) learns the
out/in path to a node. `get_advert_path/2` returns the last advert's path.

## Telemetry dashboards

Poll `req_telemetry_sync/3` from a `GenServer`:

```elixir
defmodule Poller do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :poll)
    {:ok, Map.new(opts)}
  end

  @impl true
  def handle_info(:poll, %{mc: mc, node: node, every: every} = state) do
    case Meshcore.Commands.req_telemetry_sync(mc, Meshcore.get_contact_by_name(mc, node)) do
      {:ok, lpp} -> :telemetry.execute([:my_app, :mesh, :sensor], %{readings: lpp}, %{node: node})
      {:error, e} -> Logger.warning("telemetry failed: #{inspect(e.payload)}")
    end

    Process.send_after(self(), :poll, every)
    {:noreply, state}
  end
end
```

A failed poll is just a log line – the GenServer, and the connection, carry on.
