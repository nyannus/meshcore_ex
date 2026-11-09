defmodule Meshcore.Reader do
  @moduledoc """
  Decodes frames received from the device into `Meshcore.Event`s.

  The reader is a **pure** state machine (no processes): `handle_rx/2` takes a
  frame and returns the events it produced together with the updated reader.
  It keeps only the state needed to turn frames into events:

    * the contact list currently being received (`CONTACT_START` … `CONTACT_END`),
    * pending binary requests (so `:binary_response` frames can be decoded into
      `:status_response`, `:telemetry_response`, `:mma_response`,
      `:acl_response` and `:neighbours_response` events),
    * the `Meshcore.PacketParser` used for RX-log decoding and channel-message
      path correlation.

  Malformed or truncated frames never raise: they are logged and dropped, as in
  the Python implementation.
  """

  require Logger
  import Bitwise
  import Meshcore.Util

  alias Meshcore.{Event, Lpp, PacketParser, Parsing}

  @type pending :: %{
          request_type: atom(),
          pubkey_prefix: String.t(),
          expires_at: integer(),
          is_anon: boolean(),
          context: map()
        }

  @type t :: %__MODULE__{
          contacts: %{String.t() => map()},
          contact_nb: non_neg_integer(),
          pending_binary_requests: %{String.t() => pending()},
          parser: PacketParser.t()
        }
  defstruct contacts: %{}, contact_nb: 0, pending_binary_requests: %{}, parser: %PacketParser{}

  @doc "Creates a new reader."
  @spec new() :: t()
  def new, do: %__MODULE__{parser: PacketParser.new()}

  @doc "Enables or disables decryption of group-channel packets in the RX log."
  @spec set_decrypt_channels(t(), boolean()) :: t()
  def set_decrypt_channels(%__MODULE__{} = r, value),
    do: %{r | parser: %{r.parser | decrypt_channels: value}}

  @doc "Whether channel decryption is enabled."
  @spec decrypt_channels?(t()) :: boolean()
  def decrypt_channels?(%__MODULE__{parser: p}), do: p.decrypt_channels

  @doc """
  Registers a pending binary request keyed by its expected `tag` (hex), so the
  matching `:binary_response` can be decoded. Expired registrations are purged.

  Options: `:context` (map copied into the result), `:is_anon` (boolean).
  """
  @spec register_binary_request(t(), String.t(), String.t(), atom(), non_neg_integer(), keyword()) ::
          t()
  def register_binary_request(
        %__MODULE__{} = r,
        prefix,
        tag,
        request_type,
        timeout_ms,
        opts \\ []
      ) do
    r = cleanup_expired(r)

    entry = %{
      request_type: request_type,
      pubkey_prefix: prefix,
      expires_at: System.monotonic_time(:millisecond) + timeout_ms,
      is_anon: Keyword.get(opts, :is_anon, false),
      context: Keyword.get(opts, :context, %{})
    }

    %{r | pending_binary_requests: Map.put(r.pending_binary_requests, tag, entry)}
  end

  @doc "Drops expired pending binary requests."
  @spec cleanup_expired(t()) :: t()
  def cleanup_expired(%__MODULE__{} = r) do
    now = System.monotonic_time(:millisecond)
    pending = Map.reject(r.pending_binary_requests, fn {_tag, %{expires_at: e}} -> now > e end)
    %{r | pending_binary_requests: pending}
  end

  @doc """
  Decodes one frame. Returns `{events, reader}`; `events` is in dispatch order.
  """
  @spec handle_rx(t(), binary()) :: {[Event.t()], t()}
  def handle_rx(%__MODULE__{} = reader, <<>>) do
    Logger.warning("Received empty packet")
    {[], reader}
  end

  def handle_rx(%__MODULE__{} = reader, <<code, body::binary>> = data) do
    Logger.debug(fn -> "Received data: #{hex(data)}" end)
    rx(code, body, data, reader)
  rescue
    e ->
      Logger.error(
        "handle_rx parse error: #{Exception.format(:error, e, __STACKTRACE__)} | raw=#{hex(data)}"
      )

      {[], reader}
  end

  defp ev(type, payload, attrs \\ %{}),
    do: %Event{type: type, payload: payload, attributes: attrs}

  defp one(reader, event), do: {[event], reader}
  defp none(reader), do: {[], reader}

  defp snr(<<v::signed-8>>), do: v / 4

  # ---- command responses ---------------------------------------------------

  defp rx(0x00, body, data, r) do
    payload =
      if byte_size(data) == 5, do: %{value: :binary.decode_unsigned(body, :little)}, else: %{}

    one(r, ev(:ok, payload))
  end

  defp rx(0x01, body, _data, r) do
    payload =
      case body do
        <<code, _::binary>> ->
          base = %{error_code: code}
          if msg = Event.error_message(code), do: Map.put(base, :code_string, msg), else: base

        _ ->
          %{}
      end

    one(r, ev(:error, payload))
  end

  defp rx(0x02, <<n::little-32, _::binary>>, _data, r),
    do: none(%{r | contact_nb: n, contacts: %{}})

  defp rx(0x03, body, _data, r) do
    contact = decode_contact(body)

    {[ev(:next_contact, contact)],
     %{r | contacts: Map.put(r.contacts, contact.public_key, contact)}}
  end

  defp rx(0x8A, body, _data, r), do: one(r, ev(:new_contact, decode_contact(body)))

  defp rx(0x16, <<ts::little-32, plen, rest::binary>>, _data, r) do
    {mode, len} = split_path_len(plen)
    count = max(len, 0) * (max(mode, -1) + 1)
    take = min(count, byte_size(rest))
    <<path::binary-size(take), _::binary>> = rest

    one(
      r,
      ev(:advert_path, %{timestamp: ts, path_hash_mode: mode, path_len: len, path: hex(path)})
    )
  end

  defp rx(0x04, <<lastmod::little-32, _::binary>>, _data, r),
    do: one(r, ev(:contacts, r.contacts, %{lastmod: lastmod}))

  defp rx(0x05, body, _data, r) do
    <<adv_type, tx_power, max_tx_power, pubkey::binary-32, lat::little-signed-32,
      lon::little-signed-32, multi_acks, adv_loc_policy, telemetry_mode, manual_add,
      freq::little-32, bw::little-32, sf, cr, name::binary>> = body

    info = %{
      adv_type: adv_type,
      tx_power: tx_power,
      max_tx_power: max_tx_power,
      public_key: hex(pubkey),
      adv_lat: lat / 1.0e6,
      adv_lon: lon / 1.0e6,
      multi_acks: multi_acks,
      adv_loc_policy: adv_loc_policy,
      telemetry_mode_env: telemetry_mode >>> 4 &&& 0b11,
      telemetry_mode_loc: telemetry_mode >>> 2 &&& 0b11,
      telemetry_mode_base: telemetry_mode &&& 0b11,
      manual_add_contacts: manual_add > 0,
      radio_freq: freq / 1000,
      radio_bw: bw / 1000,
      radio_sf: sf,
      radio_cr: cr,
      name: utf8(name)
    }

    one(r, ev(:self_info, info))
  end

  defp rx(0x1C, body, data, r) do
    # Firmware sends a 48 byte frame when a scope is set and a bare code otherwise.
    payload =
      case body do
        <<name::binary-31, key::binary-16, _::binary>> when byte_size(data) >= 48 ->
          %{scope_name: cstr(name), scope_key: hex(key)}

        _ ->
          %{}
      end

    one(r, ev(:default_flood_scope, payload))
  end

  defp rx(0x06, <<type, ack::binary-4, timeout::little-32, _::binary>>, _data, r) do
    payload = %{type: type, expected_ack: ack, suggested_timeout: timeout}
    one(r, ev(:msg_sent, payload, %{type: type, expected_ack: hex(ack)}))
  end

  defp rx(0x07, body, _data, r) do
    <<prefix::binary-6, plen, txt_type, ts::little-32, rest::binary>> = body
    one(r, contact_msg(prefix, plen, txt_type, ts, rest, %{}))
  end

  defp rx(0x10, body, _data, r) do
    <<snr_b::binary-1, _reserved::binary-2, prefix::binary-6, plen, txt_type, ts::little-32,
      rest::binary>> = body

    one(r, contact_msg(prefix, plen, txt_type, ts, rest, %{snr: snr(snr_b)}))
  end

  defp rx(0x08, body, _data, r) do
    <<idx, plen, txt_type, ts::little-32, rest::binary>> = body
    text = strip_nul(rest)

    res =
      %{type: "CHAN", channel_idx: idx}
      |> Map.merge(path_fields(plen))
      |> Map.merge(%{txt_type: txt_type, sender_timestamp: ts, text: utf8(text)})

    res =
      if decrypt_channels?(r) do
        case PacketParser.find_log_channel_msg(r.parser, PacketParser.text_hash(ts, text)) do
          nil ->
            res

          logged ->
            Map.merge(res, %{
              path: logged[:path],
              rssi: logged[:rssi],
              snr: logged[:snr],
              recv_time: logged[:recv_time],
              attempt: logged[:attempt]
            })
        end
      else
        res
      end

    one(r, ev(:channel_msg_recv, res, %{channel_idx: idx, txt_type: txt_type}))
  end

  defp rx(0x11, body, _data, r) do
    <<snr_b::binary-1, _reserved::binary-2, idx, plen, txt_type, ts::little-32, text::binary>> =
      body

    res =
      %{type: "CHAN", snr: snr(snr_b), channel_idx: idx}
      |> Map.merge(path_fields(plen))
      |> Map.merge(%{txt_type: txt_type, sender_timestamp: ts, text: utf8(text)})

    res =
      if decrypt_channels?(r) do
        txt_hash = PacketParser.text_hash(ts, text)
        res = Map.put(res, :txt_hash, txt_hash)

        case PacketParser.find_log_channel_msg(r.parser, txt_hash) do
          nil ->
            res

          logged ->
            Map.merge(res, %{
              path: logged[:path],
              rssi: logged[:rssi],
              recv_time: logged[:recv_time],
              attempt: logged[:attempt]
            })
        end
      else
        res
      end

    one(r, ev(:channel_msg_recv, res, %{channel_idx: idx, txt_type: txt_type}))
  end

  defp rx(0x1B, body, data, r) when byte_size(data) >= 9 do
    <<snr_b::binary-1, _reserved::binary-2, idx, plen, data_type::little-16, len, rest::binary>> =
      body

    take = min(len, byte_size(rest))
    <<payload::binary-size(take), _::binary>> = rest

    res =
      %{type: "DATA", snr: snr(snr_b), channel_idx: idx}
      |> Map.merge(path_fields(plen))
      |> Map.merge(%{data_type: data_type, data_len: len, payload: hex(payload)})

    one(r, ev(:channel_data_recv, res, %{channel_idx: idx, data_type: data_type}))
  end

  defp rx(0x1B, _body, data, r) do
    Logger.debug("CHANNEL_DATA_RECV frame too short (#{byte_size(data)} bytes < 9), skipping")
    none(r)
  end

  defp rx(0x09, <<t::little-32, _::binary>>, _data, r), do: one(r, ev(:current_time, %{time: t}))
  defp rx(0x0A, _body, _data, r), do: one(r, ev(:no_more_msgs, %{messages_available: false}))
  defp rx(0x0B, body, _data, r), do: one(r, ev(:contact_uri, %{uri: "meshcore://" <> hex(body)}))

  defp rx(0x0C, body, data, r) do
    cond do
      byte_size(data) < 3 ->
        Logger.debug("BATTERY frame too short (#{byte_size(data)} bytes < 3), skipping")
        none(r)

      byte_size(data) >= 11 ->
        <<level::little-16, used::little-32, total::little-32, _::binary>> = body
        one(r, ev(:battery, %{level: level, used_kb: used, total_kb: total}))

      true ->
        <<level::little-16, _::binary>> = body
        one(r, ev(:battery, %{level: level}))
    end
  end

  defp rx(0x0D, <<fw_ver, rest::binary>>, _data, r) do
    res = %{fw_ver: fw_ver}

    {res, rest} =
      if fw_ver >= 3 do
        <<max_contacts, max_channels, ble_pin::little-32, build::binary-12, model::binary-40,
          ver::binary-20, rest::binary>> = rest

        {Map.merge(res, %{
           max_contacts: max_contacts * 2,
           max_channels: max_channels,
           ble_pin: ble_pin,
           fw_build: cstr(build),
           model: cstr(model),
           ver: cstr(ver)
         }), rest}
      else
        {res, rest}
      end

    {res, rest} =
      case {fw_ver >= 9, rest} do
        {true, <<rpt, rest::binary>>} -> {Map.put(res, :repeat, rpt != 0), rest}
        _ -> {res, rest}
      end

    res =
      case {fw_ver >= 10, rest} do
        {true, <<mode, _::binary>>} -> Map.put(res, :path_hash_mode, mode)
        _ -> res
      end

    one(r, ev(:device_info, res))
  end

  defp rx(0x15, body, _data, r) do
    vars =
      body
      |> utf8()
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn pair ->
        case String.split(pair, ":", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)
      |> Map.new()

    one(r, ev(:custom_vars, vars))
  end

  defp rx(0x18, <<>>, _data, r) do
    Logger.error("Stats response too short: need at least 2 bytes for header")
    one(r, ev(:error, %{reason: :invalid_frame_length}))
  end

  defp rx(0x18, <<type, _::binary>> = body, data, r), do: stats(type, body, data, r)

  defp rx(0x19, body, data, r) do
    <<config, rest::binary>> = body
    res = %{config: config}

    res =
      case rest do
        <<hops, _::binary>> when byte_size(data) >= 3 -> Map.put(res, :max_hops, hops)
        _ -> res
      end

    one(r, ev(:autoadd_config, res, res))
  end

  defp rx(0x12, body, _data, r) do
    <<idx, name::binary-32, secret::binary-16, _::binary>> = body

    name =
      case :binary.match(name, <<0>>) do
        {pos, _} -> binary_part(name, 0, pos)
        :nomatch -> name
      end

    <<hash::binary-1, _::binary>> = sha256(secret)

    res = %{
      channel_idx: idx,
      channel_name: utf8(name),
      channel_secret: secret,
      channel_hash: hex(hash)
    }

    r = %{r | parser: PacketParser.new_channel(r.parser, res)}
    one(r, ev(:channel_info, res, res))
  end

  # ---- push notifications --------------------------------------------------

  defp rx(0x80, <<key::binary-32, _::binary>>, _data, r) do
    res = %{public_key: hex(key)}
    one(r, ev(:advertisement, res, res))
  end

  defp rx(0x81, <<key::binary-32, _::binary>>, _data, r) do
    res = %{public_key: hex(key)}
    one(r, ev(:path_update, res, res))
  end

  defp rx(0x82, body, data, r) do
    res = if byte_size(data) >= 5, do: %{code: hex(binary_part(body, 0, 4))}, else: %{}

    res =
      if byte_size(data) >= 9 do
        <<_::binary-4, trip::little-32, _::binary>> = body
        Map.put(res, :trip_time, trip)
      else
        res
      end

    one(r, ev(:ack, res, %{code: Map.get(res, :code, "")}))
  end

  defp rx(0x83, _body, _data, r), do: one(r, ev(:messages_waiting, %{}))

  defp rx(0x84, <<snr_b::binary-1, rssi::signed-8, _reserved, payload::binary>>, _data, r),
    do: one(r, ev(:raw_data, %{snr: snr(snr_b), rssi: rssi, payload: hex(payload)}))

  defp rx(0x85, body, data, r) do
    len = byte_size(data)
    {res, attrs} = login_success(body, len)
    one(r, ev(:login_success, res, attrs))
  end

  defp rx(0x86, body, data, r) do
    <<_reserved, rest::binary>> = body

    {res, attrs} =
      case rest do
        <<prefix::binary-6, _::binary>> when byte_size(data) > 7 ->
          p = hex(prefix)
          {%{pubkey_prefix: p}, %{pubkey_prefix: p}}

        _ ->
          {%{}, %{}}
      end

    one(r, ev(:login_failed, res, attrs))
  end

  defp rx(0x87, _body, data, r) when byte_size(data) < 60 do
    Logger.debug("STATUS_RESPONSE push frame too short (#{byte_size(data)} bytes < 60), skipping")
    none(r)
  end

  defp rx(0x87, _body, data, r) do
    res = Parsing.parse_status(data, nil, 8)
    one(r, ev(:status_response, res, %{pubkey_prefix: res.pubkey_pre}))
  end

  defp rx(0x88, body, data, r) do
    recv_time = now()
    log = %{raw_hex: hex(body), recv_time: recv_time}
    attrs = %{recv_time: recv_time}
    len = byte_size(data)

    {log, rest} =
      case body do
        <<s::binary-1, rest::binary>> when len > 1 -> {Map.put(log, :snr, snr(s)), rest}
        _ -> {log, <<>>}
      end

    {log, rest} =
      case rest do
        <<rssi::signed-8, rest::binary>> when len > 2 -> {Map.put(log, :rssi, rssi), rest}
        _ -> {log, <<>>}
      end

    if len > 3 do
      log = Map.merge(log, %{payload: hex(rest), payload_length: byte_size(rest)})
      {log, parser} = PacketParser.parse_packet_payload(r.parser, rest, log)

      attrs =
        Map.merge(attrs, %{
          route_type: log.route_type,
          payload_type: log.payload_type,
          path_len: log.path_len,
          path: log.path
        })

      {[ev(:rx_log_data, log, attrs)], %{r | parser: parser}}
    else
      one(r, ev(:rx_log_data, log, attrs))
    end
  end

  defp rx(0x89, body, data, r) do
    <<_reserved, path_len, flags, tag::little-32, auth::little-32, rest::binary>> = body
    hash_len = 1 <<< (flags &&& 3)
    path_len = div(path_len, hash_len)
    res = %{tag: tag, auth: auth, flags: flags, path_len: path_len}

    res =
      if path_len > 0 and byte_size(data) >= 12 + path_len + path_len * hash_len + 1 do
        hashes_size = path_len * hash_len

        <<hashes::binary-size(hashes_size), snrs::binary-size(path_len), final::binary-1,
          _::binary>> = rest

        nodes =
          Enum.zip(
            for(<<h::binary-size(hash_len) <- hashes>>, do: hex(h)),
            for(<<s::signed-8 <- snrs>>, do: s / 4.0)
          )
          |> Enum.map(fn {h, s} -> %{hash: h, snr: s} end)

        Map.put(res, :path, nodes ++ [%{snr: snr(final)}])
      else
        res
      end

    one(r, ev(:trace_data, res, %{tag: tag, auth_code: auth}))
  end

  defp rx(0x8B, <<_reserved, pre::binary-6, buf::binary>>, _data, r) do
    case Lpp.parse(buf) do
      {:ok, lpp} ->
        p = hex(pre)

        one(
          r,
          ev(:telemetry_response, %{pubkey_pre: p, lpp: lpp}, %{raw: hex(buf), pubkey_prefix: p})
        )

      {:error, reason} ->
        Logger.error("Error parsing telemetry response: #{inspect(reason)}")
        none(r)
    end
  end

  defp rx(0x1A, body, _data, r) do
    freqs = for <<min::little-32, max::little-32 <- body>>, do: {min, max}

    freqs =
      freqs
      |> Enum.take_while(fn {min, max} -> min != 0 and max != 0 end)
      |> Enum.map(fn {min, max} -> %{min: min, max: max} end)

    one(r, ev(:allowed_repeat_freq, %{freqs: freqs}))
  end

  defp rx(0x8C, <<_reserved, tag::binary-4, response::binary>>, _data, r) do
    tag = hex(tag)
    Logger.debug("Received binary data: tag #{tag}, data #{hex(response)}")

    base = ev(:binary_response, %{tag: tag, data: hex(response)}, %{tag: tag})

    case Map.pop(r.pending_binary_requests, tag) do
      {nil, _} ->
        Logger.debug("No tracked request found for binary response tag #{tag}")
        one(r, base)

      {%{is_anon: true}, pending} ->
        one(%{r | pending_binary_requests: pending}, base)

      {entry, pending} ->
        r = %{r | pending_binary_requests: pending}
        {[base | binary_response(entry, tag, response)], r}
    end
  end

  defp rx(0x8D, <<_reserved, pre::binary-6, opl, rest::binary>>, _data, r) do
    {out_hlen, out_len} = {((opl &&& 0xC0) >>> 6) + 1, opl &&& 0x3F}
    out_bytes = out_len * out_hlen
    <<out_path::binary-size(out_bytes), ipl, rest::binary>> = rest
    {in_hlen, in_len} = {((ipl &&& 0xC0) >>> 6) + 1, ipl &&& 0x3F}
    in_bytes = in_len * in_hlen
    <<in_path::binary-size(in_bytes), _::binary>> = rest
    p = hex(pre)

    res = %{
      pubkey_pre: p,
      out_path_len: out_len,
      out_path_hash_len: out_hlen,
      out_path: hex(out_path),
      in_path_len: in_len,
      in_path_hash_len: in_hlen,
      in_path: hex(in_path)
    }

    one(r, ev(:path_response, res, %{pubkey_pre: p}))
  end

  defp rx(0x0E, body, data, r) do
    if byte_size(data) >= 65 do
      <<key::binary-64, _::binary>> = body
      one(r, ev(:private_key, %{private_key: key}))
    else
      Logger.error("Invalid private key response length: #{byte_size(data)}")
      none(r)
    end
  end

  defp rx(0x13, <<_reserved, max::little-32, _::binary>>, _data, r),
    do: one(r, ev(:sign_start, %{max_length: max}))

  defp rx(0x14, body, _data, r), do: one(r, ev(:signature, %{signature: body}))

  defp rx(0x0F, _body, _data, r),
    do: one(r, ev(:disabled, %{reason: :private_key_export_disabled}))

  defp rx(0x8E, <<snr_b::binary-1, rssi::signed-8, path_len, payload::binary>>, _data, r) do
    case payload do
      <<>> ->
        Logger.debug("CONTROL_DATA frame has empty payload, skipping")
        none(r)

      <<payload_type, _::binary>> ->
        res = %{snr: snr(snr_b), rssi: rssi, path_len: path_len}

        control =
          ev(:control_data, Map.merge(res, %{payload_type: payload_type, payload: payload}), %{
            payload_type: payload_type
          })

        if (payload_type &&& 0xF0) == 0x90 do
          <<_, rest::binary>> = payload
          <<snr_in::binary-1, tag::binary-4, pubkey::binary>> = rest

          pubkey =
            binary_part(
              pubkey,
              0,
              min(byte_size(pubkey), if(byte_size(pubkey) < 32, do: 8, else: 32))
            )

          node_type = payload_type &&& 0x0F

          ndr =
            Map.merge(res, %{
              node_type: node_type,
              snr_in: snr(snr_in),
              tag: hex(tag),
              pubkey: hex(pubkey)
            })

          {[
             control,
             ev(:discover_response, ndr, %{node_type: node_type, tag: ndr.tag, pubkey: ndr.pubkey})
           ], r}
        else
          one(r, control)
        end
    end
  end

  defp rx(0x8F, <<key::binary-32, _::binary>>, _data, r) do
    k = hex(key)
    one(r, ev(:contact_deleted, %{pubkey: k}, %{pubkey: k}))
  end

  defp rx(0x8F, _body, data, r) do
    Logger.debug("CONTACT_DELETED frame too short (#{byte_size(data)} bytes, need 33)")
    none(r)
  end

  defp rx(0x90, _body, _data, r), do: one(r, ev(:contacts_full, %{}))

  defp rx(0x17, <<rx_delay::little-32, af::little-32, _::binary>>, _data, r),
    do: one(r, ev(:tuning_params, %{rx_delay: rx_delay, airtime_factor: af}))

  defp rx(0x17, _body, data, r) do
    Logger.debug("TUNING_PARAMS frame too short (#{byte_size(data)} bytes, need 9)")
    one(r, ev(:error, %{reason: :invalid_frame_length}))
  end

  defp rx(0x1D, body, _data, r), do: one(r, ev(:cli_reply, %{text: utf8(body)}))

  defp rx(code, _body, data, r) do
    Logger.debug("Unhandled packet type #{code}: #{hex(data)}")
    none(r)
  end

  # ---- helpers ---------------------------------------------------------------

  defp decode_contact(body) do
    <<pubkey::binary-32, type, flags, plen, path::binary-64, name::binary-32,
      last_advert::little-32, lat::little-signed-32, lon::little-signed-32, lastmod::little-32,
      _::binary>> = body

    {mode, len} = split_path_len(plen)

    out_path =
      if len > 0 do
        used = min(len * (mode + 1), 64)
        path |> binary_part(0, used) |> hex()
      else
        ""
      end

    %{
      public_key: hex(pubkey),
      type: type,
      flags: flags,
      out_path_hash_mode: mode,
      out_path_len: len,
      out_path: out_path,
      adv_name: cstr(name),
      last_advert: last_advert,
      adv_lat: lat / 1.0e6,
      adv_lon: lon / 1.0e6,
      lastmod: lastmod
    }
  end

  defp path_fields(255), do: %{path_hash_mode: -1, path_len: 255}
  defp path_fields(plen), do: %{path_hash_mode: plen >>> 6, path_len: plen &&& 0x3F}

  defp contact_msg(prefix, plen, txt_type, ts, rest, extra) do
    {signature, text} =
      if txt_type == 2 do
        <<sig::binary-4, text::binary>> = rest
        {%{signature: hex(sig)}, text}
      else
        {%{}, rest}
      end

    res =
      %{type: "PRIV", pubkey_prefix: hex(prefix)}
      |> Map.merge(extra)
      |> Map.merge(path_fields(plen))
      |> Map.merge(%{txt_type: txt_type, sender_timestamp: ts})
      |> Map.merge(signature)
      |> Map.put(:text, utf8(text))

    ev(:contact_msg_recv, res, %{pubkey_prefix: res.pubkey_prefix, txt_type: txt_type})
  end

  defp login_success(body, len) do
    res = %{}
    attrs = %{}

    {res, rest} =
      case body do
        <<perms, rest::binary>> when len > 1 ->
          {Map.merge(res, %{permissions: perms, is_admin: (perms &&& 1) == 1}), rest}

        _ ->
          {res, <<>>}
      end

    {res, attrs, rest} =
      case rest do
        <<prefix::binary-6, rest::binary>> when len > 7 ->
          p = hex(prefix)
          {Map.put(res, :pubkey_prefix, p), %{pubkey_prefix: p}, rest}

        _ ->
          {res, attrs, <<>>}
      end

    {res, rest} =
      case rest do
        <<ts::little-32, rest::binary>> when len >= 12 ->
          {Map.put(res, :server_timestamp, ts), rest}

        _ ->
          {res, <<>>}
      end

    {res, rest} =
      case rest do
        <<acl, rest::binary>> when len >= 13 -> {Map.put(res, :acl_permissions, acl), rest}
        _ -> {res, <<>>}
      end

    res =
      case rest do
        <<fw, _::binary>> when len >= 14 -> Map.put(res, :fw_ver_level, fw)
        _ -> res
      end

    {res, attrs}
  end

  defp stats(0, body, data, r) do
    case body do
      <<0, battery_mv::little-16, uptime::little-32, errors::little-16, queue_len, _::binary>> ->
        one(
          r,
          ev(:stats_core, %{
            battery_mv: battery_mv,
            uptime_secs: uptime,
            errors: errors,
            queue_len: queue_len
          })
        )

      _ ->
        Logger.error("Stats core response too short: #{byte_size(data)} bytes, expected 11")
        one(r, ev(:error, %{reason: :invalid_frame_length}))
    end
  end

  defp stats(1, body, data, r) do
    case body do
      <<1, nf::little-signed-16, rssi::signed-8, snr_s::signed-8, tx::little-32, rx::little-32,
        _::binary>> ->
        one(
          r,
          ev(:stats_radio, %{
            noise_floor: nf,
            last_rssi: rssi,
            last_snr: snr_s / 4.0,
            tx_air_secs: tx,
            rx_air_secs: rx
          })
        )

      _ ->
        Logger.error("Stats radio response too short: #{byte_size(data)} bytes, expected 14")
        one(r, ev(:error, %{reason: :invalid_frame_length}))
    end
  end

  defp stats(2, body, data, r) do
    case body do
      <<2, recv::little-32, sent::little-32, ftx::little-32, dtx::little-32, frx::little-32,
        drx::little-32, rest::binary>> ->
        errors =
          case rest do
            <<e::little-32, _::binary>> -> e
            _ -> nil
          end

        one(
          r,
          ev(:stats_packets, %{
            recv: recv,
            sent: sent,
            flood_tx: ftx,
            direct_tx: dtx,
            flood_rx: frx,
            direct_rx: drx,
            recv_errors: errors
          })
        )

      _ ->
        Logger.error(
          "Stats packets response too short: #{byte_size(data)} bytes, expected 26 or 30"
        )

        one(r, ev(:error, %{reason: :invalid_frame_length}))
    end
  end

  defp stats(type, _body, data, r) do
    Logger.error("Unknown stats type: #{type}, data: #{hex(data)}")
    one(r, ev(:error, %{reason: {:unknown_stats_type, type}}))
  end

  defp binary_response(%{request_type: :status, pubkey_prefix: prefix}, tag, response)
       when byte_size(response) >= 52 do
    res = Parsing.parse_status(response, prefix, 0)
    [ev(:status_response, res, %{pubkey_prefix: res.pubkey_pre, tag: tag})]
  end

  defp binary_response(%{request_type: :status}, _tag, _response), do: []

  defp binary_response(%{request_type: :telemetry, pubkey_prefix: prefix}, tag, response) do
    case Lpp.parse(response) do
      {:ok, lpp} ->
        res = %{tag: tag, lpp: lpp, pubkey_prefix: prefix}
        [ev(:telemetry_response, res, res)]

      {:error, reason} ->
        Logger.error("Error parsing binary telemetry response: #{inspect(reason)}")
        []
    end
  end

  defp binary_response(%{request_type: :mma, pubkey_prefix: prefix}, tag, response) do
    body =
      if byte_size(response) >= 4,
        do: binary_part(response, 4, byte_size(response) - 4),
        else: <<>>

    case Lpp.parse_mma(body) do
      {:ok, mma} ->
        res = %{tag: tag, mma_data: mma, pubkey_prefix: prefix}
        [ev(:mma_response, res, res)]

      {:error, reason} ->
        Logger.error("Error parsing binary MMA response: #{inspect(reason)}")
        []
    end
  end

  defp binary_response(%{request_type: :acl, pubkey_prefix: prefix}, tag, response) do
    res = %{tag: tag, acl_data: Parsing.parse_acl(response), pubkey_prefix: prefix}
    [ev(:acl_response, res, %{tag: tag, pubkey_prefix: prefix})]
  end

  defp binary_response(
         %{request_type: :neighbours, pubkey_prefix: prefix, context: ctx},
         tag,
         response
       ) do
    pk_len = Map.fetch!(ctx, :pubkey_prefix_length)
    <<total::little-signed-16, count::little-signed-16, rest::binary>> = response

    {neighbours, _} =
      Enum.map_reduce(1..max(count, 0)//1, rest, fn _, buf ->
        <<pk::binary-size(pk_len), secs::little-signed-32, s::signed-8, buf::binary>> = buf
        {%{pubkey: hex(pk), secs_ago: secs, snr: s / 4}, buf}
      end)

    res =
      %{pubkey_prefix: prefix, tag: tag}
      |> Map.merge(ctx)
      |> Map.merge(%{neighbours_count: total, results_count: count, neighbours: neighbours})

    [ev(:neighbours_response, res, %{tag: tag, pubkey_prefix: prefix})]
  rescue
    e ->
      Logger.error("Error parsing binary NEIGHBOURS response: #{Exception.message(e)}")
      []
  end

  defp binary_response(_entry, _tag, _response), do: []
end
