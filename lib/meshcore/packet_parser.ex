defmodule Meshcore.PacketParser do
  @moduledoc """
  Parser for raw LoRa packets seen in `:rx_log_data` events.

  It decodes the packet header and path, parses advertisements, and – when
  channel decryption is enabled – recognises and decrypts group-text packets
  for channels whose secret is known (learned from `:channel_info` events), so
  that a later `:channel_msg_recv` can be annotated with path/RSSI/SNR of the
  packet it came from.

  This is a pure data structure: every function returns the updated parser.
  """

  require Logger
  import Meshcore.Util, only: [hex: 1, utf8: 1, strip_nul: 1]

  @payload_typenames ~w(REQ RESPONSE TEXT_MSG ACK ADVERT GRP_TXT GRP_DATA ANON_REQ PATH TRACE MULTIPART CONTROL)
  @route_typenames ~w(TC_FLOOD FLOOD DIRECT TC_DIRECT)
  @max_log 100
  @drop_log 25

  @type t :: %__MODULE__{
          channels: %{non_neg_integer() => map()},
          channels_log: [map()],
          decrypt_channels: boolean()
        }
  defstruct channels: %{}, channels_log: [], decrypt_channels: false

  @doc "Creates an empty parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Remembers (or replaces) the channel at `chan.channel_idx`."
  @spec new_channel(t(), map()) :: t()
  def new_channel(%__MODULE__{} = p, %{channel_idx: idx} = chan),
    do: %{p | channels: Map.put(p.channels, idx, chan)}

  @doc "Finds the most recent logged channel packet carrying text hash `msg_hash`."
  @spec find_log_channel_msg(t(), non_neg_integer()) :: map() | nil
  def find_log_channel_msg(%__MODULE__{channels_log: log}, msg_hash),
    do:
      Enum.find(
        Enum.reverse(log),
        &(Map.get(&1, :msg_hash) == msg_hash and Map.has_key?(&1, :msg_hash))
      )

  defp find_log_channel_pkt(%__MODULE__{channels_log: log}, pkt_hash),
    do:
      Enum.find(
        Enum.reverse(log),
        &(Map.get(&1, :pkt_hash) == pkt_hash and Map.has_key?(&1, :pkt_hash))
      )

  @doc """
  Parses a raw packet `payload` and merges the findings into `log_data`.

  Returns `{log_data, parser}`.
  """
  @spec parse_packet_payload(t(), binary(), map()) :: {map(), t()}
  def parse_packet_payload(parser, payload, log_data \\ %{})

  def parse_packet_payload(parser, payload, log_data) when byte_size(payload) < 2 do
    Logger.debug("parse_packet_payload: payload too short (#{byte_size(payload)} bytes)")

    {Map.merge(log_data, %{
       route_type: -1,
       route_typename: "UNK",
       payload_type: -1,
       payload_typename: "UNK",
       payload_ver: 0,
       path_len: 0,
       path_hash_size: 1,
       path: "",
       pkt_payload: <<>>,
       pkt_hash: 0
     }), parser}
  end

  def parse_packet_payload(parser, <<header, rest::binary>>, log_data) do
    import Bitwise
    route_type = header &&& 0x03
    payload_type = (header &&& 0x3C) >>> 2
    payload_ver = (header &&& 0xC0) >>> 6

    {transport_code, rest} =
      if route_type in [0, 3] do
        case rest do
          <<tc::binary-4, r::binary>> -> {tc, r}
          r -> {nil, r}
        end
      else
        {nil, rest}
      end

    case rest do
      <<path_byte, rest::binary>> ->
        path_hash_size = ((path_byte &&& 0xC0) >>> 6) + 1
        path_len = path_byte &&& 0x3F
        take = min(path_len * path_hash_size, byte_size(rest))
        <<path::binary-size(take), pkt_payload::binary>> = rest

        pkt_hash = pkt_hash(pkt_payload)

        log_data =
          Map.merge(log_data, %{
            header: header,
            route_type: route_type,
            route_typename: Enum.at(@route_typenames, route_type, "UNK"),
            payload_type: payload_type,
            payload_typename: Enum.at(@payload_typenames, payload_type, "UNK"),
            payload_ver: payload_ver,
            path_len: path_len,
            path_hash_size: path_hash_size,
            path: hex(path),
            pkt_payload: pkt_payload,
            pkt_hash: pkt_hash
          })

        log_data =
          if transport_code,
            do: Map.put(log_data, :transport_code, hex(transport_code)),
            else: log_data

        case payload_type do
          5 -> grp_txt(parser, pkt_payload, pkt_hash, log_data)
          4 -> {advert(pkt_payload, log_data), parser}
          _ -> {log_data, parser}
        end

      <<>> ->
        parse_packet_payload(parser, <<>>, log_data)
    end
  end

  defp pkt_hash(pkt_payload) do
    <<h::little-32, _::binary>> = Meshcore.Util.sha256(pkt_payload)
    h
  end

  defp msg_hash(timestamp, message) do
    <<h::little-32, _::binary>> = Meshcore.Util.sha256(<<timestamp::little-32>> <> message)
    h
  end

  @doc false
  def text_hash(timestamp, message), do: msg_hash(timestamp, message)

  # group text (channel message)
  defp grp_txt(parser, pkt_payload, pkt_hash, log_data) do
    {chan_hash, cipher_mac, msg} =
      case pkt_payload do
        <<h::binary-1, mac::binary-2, msg::binary>> -> {hex(h), mac, msg}
        other -> {hex(binary_part(other, 0, min(1, byte_size(other)))), <<>>, <<>>}
      end

    channel = find_channel(parser, chan_hash, cipher_mac, msg)

    log_data =
      Map.merge(log_data, %{chan_hash: chan_hash, cipher_mac: hex(cipher_mac), crypted: hex(msg)})

    log_data = if channel, do: Map.put(log_data, :chan_name, channel.channel_name), else: log_data

    log_data =
      if channel && parser.decrypt_channels do
        case find_log_channel_pkt(parser, pkt_hash) do
          nil -> decrypt(channel, msg, log_data)
          logged -> copy_logged(logged, log_data)
        end
      else
        log_data
      end

    {log_data, push_log(parser, log_data)}
  end

  defp find_channel(parser, chan_hash, cipher_mac, msg) do
    parser.channels
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {_idx, c} ->
      with true <- Map.get(c, :channel_hash) == chan_hash,
           secret when is_binary(secret) <- Map.get(c, :channel_secret),
           <<mac::binary-2, _::binary>> <- :crypto.mac(:hmac, :sha256, secret, msg),
           true <- mac == cipher_mac do
        c
      else
        _ -> nil
      end
    end)
  end

  defp decrypt(channel, msg, log_data) do
    plain = :crypto.crypto_one_time(:aes_128_ecb, channel.channel_secret, msg, false)

    <<timestamp::little-32, flags, message::binary>> = plain
    message = strip_nul(message)

    Map.merge(log_data, %{
      message: utf8(message),
      msg_hash: msg_hash(timestamp, message),
      sender_timestamp: timestamp,
      attempt: Bitwise.band(flags, 3),
      txt_type: Bitwise.bsr(flags, 2)
    })
  rescue
    e ->
      Logger.debug("could not decrypt channel packet: #{Exception.message(e)}")
      log_data
  end

  defp copy_logged(logged, log_data) do
    Map.merge(log_data, %{
      message: Map.get(logged, :message),
      msg_hash: Map.get(logged, :msg_hash),
      sender_timestamp: Map.get(logged, :sender_timestamp),
      attempt: Map.get(logged, :attempt),
      txt_type: Map.get(logged, :txt_type)
    })
  end

  defp push_log(parser, log_data) do
    log = parser.channels_log ++ [log_data]
    log = if length(log) > @max_log, do: Enum.drop(log, @drop_log), else: log
    %{parser | channels_log: log}
  end

  # advertisement
  defp advert(
         <<key::binary-32, ts::little-32, signature::binary-64, flags, rest::binary>>,
         log_data
       ) do
    import Bitwise

    {lat, lon, rest} =
      if (flags &&& 0x10) > 0 do
        case rest do
          <<la::little-signed-32, lo::little-signed-32, r::binary>> ->
            {la / 1_000_000, lo / 1_000_000, r}

          r ->
            {nil, nil, r}
        end
      else
        {nil, nil, rest}
      end

    {feat1, rest} = optional_feature(flags, 0x20, rest)
    {feat2, rest} = optional_feature(flags, 0x40, rest)

    name =
      if (flags &&& 0x80) > 0,
        do: rest |> utf8() |> String.trim("\0"),
        else: nil

    log_data
    |> Map.merge(%{
      adv_key: hex(key),
      adv_timestamp: ts,
      signature: hex(signature),
      adv_flags: flags,
      adv_type: flags &&& 0x0F
    })
    |> put_unless_nil(:adv_name, name)
    |> put_unless_nil(:adv_lat, lat)
    |> put_unless_nil(:adv_lon, lon)
    |> put_unless_nil(:adv_feat1, feat1)
    |> put_unless_nil(:adv_feat2, feat2)
  end

  defp advert(pkt_payload, log_data) do
    Logger.debug("parse_packet_payload: malformed ADVERT payload, len=#{byte_size(pkt_payload)}")
    log_data
  end

  defp optional_feature(flags, bit, rest) do
    if Bitwise.band(flags, bit) > 0 do
      case rest do
        <<f::binary-2, r::binary>> -> {hex(f), r}
        r -> {nil, r}
      end
    else
      {nil, rest}
    end
  end

  defp put_unless_nil(map, _k, nil), do: map
  defp put_unless_nil(map, k, v), do: Map.put(map, k, v)
end
