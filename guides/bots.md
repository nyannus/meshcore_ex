# Bots

Three bots from the Python examples, as supervised processes. They share a pattern: subscribe
with an `attribute_filters` on the channel, reply with `send_chan_msg/4`, and keep going no matter
what a single message does.

> The snippets use the `JSON` module that ships with Elixir 1.18 and `:httpc` from OTP, so
> there are no extra dependencies. Swap in `Req` if you prefer.

## Ping bot (`serial_pingbot`)

Answers `ping` on one channel with a `Pong` that includes the hop path of the message it
heard. To know the path it keeps the most recent `:rx_log_data` summary.

```elixir
defmodule PingBot do
  use GenServer
  require Logger

  @channel 1

  def start_link(mc), do: GenServer.start_link(__MODULE__, mc)

  @impl true
  def init(mc) do
    {:ok, _} = Meshcore.subscribe(mc, :channel_msg_recv, attribute_filters: %{channel_idx: @channel})
    {:ok, _} = Meshcore.subscribe(mc, :rx_log_data)
    :ok = Meshcore.start_auto_message_fetching(mc)
    {:ok, %{mc: mc, pathinfo: "(? hops, ?)"}}
  end

  @impl true
  def handle_info({:meshcore, _, %Meshcore.Event{type: :rx_log_data, payload: p}}, state) do
    {:noreply, %{state | pathinfo: format_path(p)}}
  end

  def handle_info({:meshcore, _, %Meshcore.Event{type: :channel_msg_recv, payload: msg}}, state) do
    sender = msg.text |> String.split(":", parts: 2) |> hd() |> String.trim()

    if String.contains?(String.downcase(msg.text), "ping") do
      reply = "@[#{sender}] Pong 🏓#{state.pathinfo}"

      case Meshcore.Commands.send_chan_msg(state.mc, @channel, reply) do
        {:ok, _} -> Logger.info("replied: #{reply}")
        {:error, e} -> Logger.error("could not reply: #{inspect(e.payload)}")
      end
    end

    {:noreply, state}
  end

  defp format_path(%{path_len: 0}), do: "(0 hops, direct)"

  defp format_path(%{path_len: n, path: path, path_hash_size: size}) when is_integer(n) and n > 0 do
    hops = for <<hop::binary-size(size * 2) <- path>>, do: hop
    "(#{n} hops, #{Enum.join(hops, ":")})"
  end

  defp format_path(_), do: "(? hops, ?)"
end

{:ok, mc} = Meshcore.create_serial("/dev/ttyUSB0")
{:ok, _bot} = PingBot.start_link(mc)
Process.sleep(:infinity)
```

(The Python version re-parses the raw hex itself; here `Meshcore.PacketParser` already did.)

## RSS bot (`serial_rss_bot`)

Polls an RSS feed and posts new items that match a keyword filter to channels, pausing between
messages (LoRa duty cycle).

```elixir
defmodule RssBot do
  use GenServer
  require Logger

  @url ~c"https://data.emergency.vic.gov.au/Show?pageId=getIncidentRSS"
  @channels [6]
  @poll_ms 300_000
  @pause_ms 5_000
  @keywords ["BUSHFIRE"]

  def start_link(mc), do: GenServer.start_link(__MODULE__, mc)

  @impl true
  def init(mc) do
    # prime: don't spam what's already in the feed
    seen = fetch() |> Enum.map(& &1.id) |> MapSet.new()
    Process.send_after(self(), :poll, @poll_ms)
    {:ok, %{mc: mc, seen: seen}}
  end

  @impl true
  def handle_info(:poll, %{mc: mc, seen: seen} = state) do
    items = fetch()
    new = items |> Enum.reject(&MapSet.member?(seen, &1.id)) |> Enum.reverse()

    for item <- new, text <- List.wrap(message(item)), ch <- @channels do
      case Meshcore.Commands.send_chan_msg(mc, ch, text) do
        {:ok, _} -> :ok
        {:error, e} -> Logger.error("RSS post to channel #{ch} failed: #{inspect(e.payload)}")
      end

      Process.sleep(@pause_ms)
    end

    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, %{state | seen: Enum.reduce(items, seen, &MapSet.put(&2, &1.id))}}
  end

  defp message(%{title: title, description: desc}) do
    if Enum.any?(@keywords, &String.contains?(String.upcase(desc), &1)),
      do: String.slice("#{title} | #{desc}", 0, 135)
  end

  # Minimal feed reader – use a real XML library (SweetXml, Saxy…) for anything serious.
  defp fetch do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    case :httpc.request(:get, {@url, []}, [timeout: 15_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} ->
        for [item] <- Regex.scan(~r/<item>(.*?)<\/item>/s, body, capture: :all_but_first) do
          %{
            id: tag(item, "guid") || tag(item, "link") || tag(item, "title"),
            title: tag(item, "title") || "",
            description: tag(item, "description") || ""
          }
        end

      other ->
        Logger.warning("RSS fetch failed: #{inspect(other)}")
        []
    end
  end

  defp tag(xml, name) do
    case Regex.run(~r/<#{name}[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/#{name}>/s, xml) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end
end
```

A failing poll never kills the bot's connection; if the process itself crashes its supervisor
restarts it with a fresh `seen` set (the priming step prevents re-posting the backlog).

## LLM bot (`serial_meshcore_ollama`)

Answers prompts sent on a channel (`"alice: what is LoRa?"`) using a local
[Ollama](https://ollama.com) server, with a hard length cap for the radio.

```elixir
defmodule OllamaBot do
  use GenServer
  require Logger

  @channel 4
  @model "qwen:0.5b"
  @max_reply 120

  def start_link(mc), do: GenServer.start_link(__MODULE__, mc)

  @impl true
  def init(mc) do
    {:ok, _} = Meshcore.subscribe(mc, :channel_msg_recv, attribute_filters: %{channel_idx: @channel})
    :ok = Meshcore.start_auto_message_fetching(mc)
    {:ok, mc}
  end

  @impl true
  def handle_info({:meshcore, _, %Meshcore.Event{payload: %{text: text}}}, mc) do
    with [sender, prompt] <- String.split(text, ":", parts: 2),
         prompt = String.trim(prompt),
         true <- prompt != "" do
      # don't block the bot while the model thinks
      Task.start(fn -> answer(mc, String.trim(sender), prompt) end)
    end

    {:noreply, mc}
  end

  defp answer(mc, sender, prompt) do
    prefix = "@[#{sender}] "
    room = max(@max_reply - String.length(prefix), 0)

    reply =
      case ask(prompt) do
        {:ok, text} -> text |> String.split() |> Enum.join(" ") |> String.slice(0, room)
        {:error, _} -> "Sorry, something went wrong on my side." |> String.slice(0, room)
      end

    Meshcore.Commands.send_chan_msg(mc, @channel, String.slice(prefix <> reply, 0, @max_reply))
  end

  defp ask(prompt) do
    body = JSON.encode!(%{model: @model, stream: false, messages: [%{role: "user", content: prompt}]})
    {:ok, _} = Application.ensure_all_started(:inets)

    case :httpc.request(:post, {~c"http://localhost:11434/api/chat", [], ~c"application/json", body},
           [timeout: 60_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, resp |> JSON.decode!() |> get_in(["message", "content"]) |> String.trim()}

      other ->
        Logger.warning("ollama request failed: #{inspect(other)}")
        {:error, other}
    end
  end
end
```

## Putting a bot under a supervisor

```elixir
children = [
  {Meshcore,
   name: MyApp.Radio,
   transport: {Meshcore.Transport.Serial, port: "/dev/ttyUSB0"},
   auto_reconnect: true,
   max_reconnect_attempts: 10},
  %{id: PingBot, start: {PingBot, :start_link, [MyApp.Radio]}}
]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

With `:rest_for_one` the bot restarts (and re-subscribes) if the connection process itself is
restarted.
