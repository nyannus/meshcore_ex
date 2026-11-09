defmodule Meshcore.ReaderTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Meshcore.Test.Frames

  alias Meshcore.{Event, Reader}

  defp rx(frame, reader \\ Reader.new()), do: Reader.handle_rx(reader, frame)
  defp one(frame, reader \\ Reader.new()), do: with({[e], _} <- rx(frame, reader), do: e)

  test "OK with and without value" do
    assert %Event{type: :ok, payload: %{}} = one(<<0>>)
    assert %Event{type: :ok, payload: %{value: 258}} = one(<<0, 2, 1, 0, 0>>)
  end

  test "ERROR carries code and name" do
    assert %Event{type: :error, payload: %{error_code: 2, code_string: "ERR_CODE_NOT_FOUND"}} =
             one(<<1, 2>>)

    assert %Event{type: :error, payload: %{error_code: 99}} = one(<<1, 99>>)
    assert %Event{type: :error, payload: %{}} = one(<<1>>)
  end

  test "self info" do
    %Event{type: :self_info, payload: p} = one(self_info())
    assert p.name == "TestNode"
    assert p.public_key == String.duplicate("ab", 32)
    assert p.adv_lat == 48.0
    assert p.adv_lon == 8.0
    assert p.multi_acks == 2
    assert p.radio_freq == 869.525
    assert p.radio_bw == 250.0
    assert p.radio_sf == 11
    assert p.radio_cr == 5
    assert p.telemetry_mode_env == 1
    assert p.telemetry_mode_loc == 2
    assert p.telemetry_mode_base == 0
    assert p.manual_add_contacts == true
  end

  test "contact list is accumulated between start and end" do
    r = Reader.new()
    {[], r} = rx(contact_start(2), r)
    {[%Event{type: :next_contact, payload: c1}], r} = rx(contact(key(1), "Alice"), r)

    {[%Event{type: :next_contact}], r} =
      rx(contact(key(2), "Bob", plen: 2, path: <<0xAA, 0xBB, 0>>), r)

    {[%Event{type: :contacts, payload: contacts, attributes: %{lastmod: 77}}], _} =
      rx(contact_end(77), r)

    assert c1.adv_name == "Alice"
    assert c1.out_path_len == -1
    assert c1.out_path == ""
    assert map_size(contacts) == 2
    bob = contacts[String.duplicate("02", 32)]
    assert bob.out_path == "aabb"
    assert bob.out_path_len == 2
    assert bob.out_path_hash_mode == 0
  end

  test "multi-byte hop hashes keep their hops (including zero bytes)" do
    path = <<0x00, 0x01, 0x02, 0x00>>
    c = one(contact(key(1), "Zed", plen: 0b01_000010, path: path))
    assert c.payload.out_path == "00010200"
    assert c.payload.out_path_hash_mode == 1
    assert c.payload.out_path_len == 2
  end

  test "new advert contact is a :new_contact event" do
    <<_::binary-1, body::binary>> = contact(key(9), "New")
    assert %Event{type: :new_contact, payload: %{adv_name: "New"}} = one(<<0x8A>> <> body)
  end

  test "msg sent" do
    assert %Event{type: :msg_sent, payload: p, attributes: attrs} =
             one(msg_sent(<<9, 8, 7, 6>>, 1, 1234))

    assert p == %{type: 1, expected_ack: <<9, 8, 7, 6>>, suggested_timeout: 1234}
    assert attrs == %{type: 1, expected_ack: "09080706"}
  end

  test "contact messages (v1 and v3) incl. flood marker and signature" do
    v1 = <<7>> <> <<1, 2, 3, 4, 5, 6>> <> <<255, 0>> <> <<1_700_000_000::little-32>> <> "hi there"
    %Event{payload: p, attributes: a} = one(v1)
    assert p.type == "PRIV"
    assert p.pubkey_prefix == "010203040506"
    assert p.path_len == 255 and p.path_hash_mode == -1
    assert p.text == "hi there"
    assert a == %{pubkey_prefix: "010203040506", txt_type: 0}

    v3 =
      <<16, -8::signed-8, 0, 0>> <>
        <<1, 2, 3, 4, 5, 6>> <>
        <<0b01_000010, 2>> <> <<5::little-32>> <> <<9, 9, 9, 9>> <> "signed"

    %Event{payload: p} = one(v3)
    assert p.snr == -2.0
    assert p.path_hash_mode == 1 and p.path_len == 2
    assert p.signature == "09090909"
    assert p.text == "signed"
  end

  test "channel messages (v1 and v3)" do
    v1 = <<8, 3, 255, 0>> <> <<42::little-32>> <> "alice: hello\0\0"
    assert %Event{payload: p, attributes: %{channel_idx: 3}} = one(v1)
    assert p.text == "alice: hello"
    assert p.type == "CHAN"

    v3 = <<17, 20, 0, 0, 1, 0b00_000001, 0>> <> <<7::little-32>> <> "bob: yo"
    assert %Event{payload: p} = one(v3)
    assert p.snr == 5.0
    assert p.channel_idx == 1
    assert p.path_len == 1
    assert p.text == "bob: yo"
  end

  test "channel data" do
    f = <<27, 8, 0, 0, 2, 255, 0x34, 0x12, 3, 1, 2, 3, 99>>
    assert %Event{type: :channel_data_recv, payload: p, attributes: a} = one(f)
    assert p.data_type == 0x1234
    assert p.payload == "010203"
    assert a == %{channel_idx: 2, data_type: 0x1234}
    assert {[], _} = rx(<<27, 1, 2>>)
  end

  test "battery with and without storage" do
    assert %Event{payload: %{level: 4000}} = one(<<12, 4000::little-16>>)

    assert %Event{payload: %{level: 4000, used_kb: 10, total_kb: 100}} =
             one(<<12, 4000::little-16, 10::little-32, 100::little-32>>)

    assert {[], _} = rx(<<12, 1>>)
  end

  test "device info across firmware tiers" do
    old = one(<<13, 2>>)
    assert old.payload == %{fw_ver: 2}

    build = pad("abc", 12)
    model = pad("Heltec V3", 40)
    ver = pad("1.2.3", 20)
    v3 = <<13, 3, 50, 8, 123_456::little-32>> <> build <> model <> ver
    assert %Event{payload: p} = one(v3)
    assert p.max_contacts == 100
    assert p.model == "Heltec V3"
    assert p.fw_build == "abc"
    assert p.ble_pin == 123_456

    assert %Event{payload: p} =
             one(
               v3
               |> binary_part(0, byte_size(v3))
               |> Kernel.<>(<<1>>)
               |> then(&(<<13, 10>> <> binary_part(&1, 2, byte_size(&1) - 2)))
               |> Kernel.<>(<<2>>)
             )

    assert p.repeat == true
    assert p.path_hash_mode == 2
  end

  test "custom vars" do
    assert %Event{payload: %{"a" => "1", "b" => "2"}} = one(<<21>> <> "a:1,b:2")
    assert %Event{payload: %{}} = one(<<21>>)
  end

  test "stats" do
    assert %Event{type: :stats_core, payload: p} =
             one(<<24, 0, 4100::little-16, 99::little-32, 3::little-16, 7>>)

    assert p == %{battery_mv: 4100, uptime_secs: 99, errors: 3, queue_len: 7}

    assert %Event{type: :stats_radio, payload: p} =
             one(
               <<24, 1, -110::little-signed-16, -90::signed-8, 22::signed-8, 5::little-32,
                 6::little-32>>
             )

    assert p.last_snr == 5.5 and p.noise_floor == -110

    legacy = <<24, 2>> <> for(n <- 1..6, into: <<>>, do: <<n::little-32>>)

    assert %Event{type: :stats_packets, payload: %{recv: 1, direct_rx: 6, recv_errors: nil}} =
             one(legacy)

    assert %Event{payload: %{recv_errors: 7}} = one(legacy <> <<7::little-32>>)

    capture_log(fn ->
      assert %Event{type: :error, payload: %{reason: :invalid_frame_length}} = one(<<24, 0, 1>>)
      assert %Event{type: :error, payload: %{reason: {:unknown_stats_type, 9}}} = one(<<24, 9>>)
    end)
  end

  test "channel info registers the channel secret" do
    secret = :binary.copy(<<7>>, 16)
    {[%Event{payload: p}], r} = rx(<<18, 2>> <> pad("#test", 32) <> secret)
    assert p.channel_name == "#test"
    assert p.channel_secret == secret

    assert p.channel_hash ==
             Base.encode16(binary_part(:crypto.hash(:sha256, secret), 0, 1), case: :lower)

    assert r.parser.channels[2].channel_name == "#test"
  end

  test "ack, login, push notifications" do
    assert %Event{
             type: :ack,
             payload: %{code: "01020304", trip_time: 120},
             attributes: %{code: "01020304"}
           } =
             one(ack(<<1, 2, 3, 4>>))

    assert %Event{attributes: %{code: ""}} = one(<<0x82>>)
    assert %Event{type: :messages_waiting} = one(<<0x83>>)

    assert %Event{type: :advertisement, payload: %{public_key: pk}} = one(<<0x80>> <> key(1))
    assert pk == String.duplicate("01", 32)
    assert %Event{type: :path_update} = one(<<0x81>> <> key(1))

    login = <<0x85, 1, 1, 2, 3, 4, 5, 6, 1000::little-32, 7, 9>>
    assert %Event{payload: p, attributes: %{pubkey_prefix: "010203040506"}} = one(login)

    assert p.is_admin and p.server_timestamp == 1000 and p.acl_permissions == 7 and
             p.fw_ver_level == 9

    assert %Event{payload: %{}} = one(<<0x85>>)

    assert %Event{type: :login_failed, payload: %{pubkey_prefix: "010203040506"}} =
             one(<<0x86, 0, 1, 2, 3, 4, 5, 6>>)
  end

  test "status push frame" do
    frame = <<0x87, 0, 1, 2, 3, 4, 5, 6>> <> status_body()

    assert %Event{
             type: :status_response,
             payload: p,
             attributes: %{pubkey_prefix: "010203040506"}
           } = one(frame)

    assert p.bat == 4100 and p.noise_floor == -110 and p.last_snr == 7.0 and p.recv_errors == 9
    assert {[], _} = rx(<<0x87, 0, 1, 2, 3>>)
  end

  test "binary response without tracking only produces the generic event" do
    assert {[%Event{type: :binary_response, payload: %{tag: "aabbccdd", data: "0102"}}], _} =
             rx(binary_response(<<0xAA, 0xBB, 0xCC, 0xDD>>, <<1, 2>>))
  end

  test "tracked status binary response is decoded and consumed" do
    r = Reader.register_binary_request(Reader.new(), "010203040506", "aabbccdd", :status, 5_000)

    {[generic, status], r} =
      rx(binary_response(<<0xAA, 0xBB, 0xCC, 0xDD>>, status_body() |> binary_part(0, 56)), r)

    assert generic.type == :binary_response
    assert status.type == :status_response
    assert status.payload.pubkey_pre == "010203040506"
    assert status.attributes == %{pubkey_prefix: "010203040506", tag: "aabbccdd"}
    assert r.pending_binary_requests == %{}
  end

  test "tracked telemetry, acl, mma and neighbours" do
    tag = <<1, 1, 1, 1>>

    r = Reader.register_binary_request(Reader.new(), "aa", "01010101", :telemetry, 5_000)
    {[_, t], _} = rx(binary_response(tag, <<1, 103, 0, 225>>), r)
    assert t.type == :telemetry_response
    assert [%{type: "temperature", value: 22.5}] = t.payload.lpp
    assert t.attributes.tag == "01010101"

    r = Reader.register_binary_request(Reader.new(), "aa", "01010101", :acl, 5_000)

    {[_, a], _} =
      rx(
        binary_response(tag, <<1, 2, 3, 4, 5, 6, 3, 0, 0, 0, 0, 0, 0, 0, 9, 9, 9, 9, 9, 9, 1>>),
        r
      )

    assert a.payload.acl_data == [
             %{key: "010203040506", perm: 3},
             %{key: "090909090909", perm: 1}
           ]

    r = Reader.register_binary_request(Reader.new(), "aa", "01010101", :mma, 5_000)

    {[_, m], _} =
      rx(
        binary_response(tag, <<0, 0, 0, 0, 1, 103, 100::big-16, 200::big-16, 150::big-16, 0>>),
        r
      )

    assert [%{min: 10.0, max: 20.0, avg: 15.0}] = m.payload.mma_data

    r =
      Reader.register_binary_request(Reader.new(), "aa", "01010101", :neighbours, 5_000,
        context: %{pubkey_prefix_length: 2}
      )

    data =
      <<5::little-signed-16, 2::little-signed-16, 0xAA, 0xBB, 60::little-signed-32, 20::signed-8,
        0xCC, 0xDD, 10::little-signed-32, -4::signed-8>>

    {[_, n], _} = rx(binary_response(tag, data), r)
    assert n.payload.neighbours_count == 5
    assert n.payload.results_count == 2

    assert [%{pubkey: "aabb", secs_ago: 60, snr: 5.0}, %{pubkey: "ccdd", snr: -1.0}] =
             n.payload.neighbours
  end

  test "anonymous requests are not decoded further" do
    r =
      Reader.register_binary_request(Reader.new(), "aa", "01010101", :status, 5_000,
        is_anon: true
      )

    assert {[%Event{type: :binary_response}], r} = rx(binary_response(<<1, 1, 1, 1>>, <<1>>), r)
    assert r.pending_binary_requests == %{}
  end

  test "expired registrations are purged on the next registration" do
    r = Reader.register_binary_request(Reader.new(), "aa", "old", :status, 0)
    Process.sleep(5)
    r = Reader.register_binary_request(r, "bb", "new", :status, 5_000)
    assert Map.keys(r.pending_binary_requests) == ["new"]
  end

  test "path discovery response" do
    f = <<0x8D, 0, 1, 2, 3, 4, 5, 6, 0b01_000001, 0xAA, 0xBB, 2, 0xCC, 0xDD>>
    assert %Event{type: :path_response, payload: p} = one(f)
    assert p.out_path == "aabb" and p.out_path_hash_len == 2 and p.out_path_len == 1
    assert p.in_path == "ccdd" and p.in_path_len == 2
  end

  test "trace data" do
    f = <<0x89, 0, 2, 0, 5::little-32, 6::little-32, 0xA1, 0xB2, 8, 12, 20>>
    assert %Event{type: :trace_data, payload: p, attributes: %{tag: 5, auth_code: 6}} = one(f)

    assert p.path == [
             %{hash: "a1", snr: 2.0},
             %{hash: "b2", snr: 3.0},
             %{snr: 5.0}
           ]
  end

  test "telemetry push" do
    assert %Event{type: :telemetry_response, payload: p} =
             one(<<0x8B, 0, 1, 2, 3, 4, 5, 6, 1, 103, 0, 225>>)

    assert p.pubkey_pre == "010203040506"
    assert [%{value: 22.5}] = p.lpp
    capture_log(fn -> assert {[], _} = rx(<<0x8B, 0, 1, 2, 3, 4, 5, 6, 1, 99, 0>>) end)
  end

  test "misc responses" do
    assert %Event{type: :current_time, payload: %{time: 1234}} = one(<<9, 1234::little-32>>)
    assert %Event{type: :no_more_msgs, payload: %{messages_available: false}} = one(<<10>>)
    assert %Event{type: :contact_uri, payload: %{uri: "meshcore://0102"}} = one(<<11, 1, 2>>)
    assert %Event{type: :disabled} = one(<<15>>)

    assert %Event{type: :sign_start, payload: %{max_length: 8192}} =
             one(<<19, 0, 8192::little-32>>)

    assert %Event{type: :signature, payload: %{signature: <<1, 2, 3>>}} = one(<<20, 1, 2, 3>>)

    assert %Event{type: :tuning_params, payload: %{rx_delay: 1, airtime_factor: 2}} =
             one(<<23, 1::little-32, 2::little-32>>)

    assert %Event{type: :autoadd_config, payload: %{config: 3, max_hops: 4}} = one(<<25, 3, 4>>)
    assert %Event{payload: %{config: 3} = p} = one(<<25, 3>>)
    refute Map.has_key?(p, :max_hops)

    assert %Event{type: :allowed_repeat_freq, payload: %{freqs: [%{min: 1, max: 2}]}} =
             one(<<26, 1::little-32, 2::little-32, 0::little-32, 0::little-32>>)

    assert %Event{type: :default_flood_scope, payload: %{}} = one(<<28>>)
    scope = <<28>> <> pad("#local", 31) <> :binary.copy(<<1>>, 16)
    assert %Event{payload: %{scope_name: "#local", scope_key: _}} = one(scope)
    assert %Event{type: :cli_reply, payload: %{text: "v1.2"}} = one(<<29, "v1.2">>)
    assert %Event{type: :contacts_full} = one(<<0x90>>)
    assert %Event{type: :contact_deleted, payload: %{pubkey: _}} = one(<<0x8F>> <> key(3))

    assert %Event{type: :raw_data, payload: %{snr: -1.0, rssi: -50, payload: "0102"}} =
             one(<<0x84, -4::signed-8, -50::signed-8, 255, 1, 2>>)

    assert %Event{type: :private_key, payload: %{private_key: k}} =
             one(<<14>> <> :binary.copy(<<1>>, 64))

    assert byte_size(k) == 64
  end

  test "control data and node discovery" do
    payload = <<0x92>> <> <<8::signed-8>> <> <<1, 2, 3, 4>> <> key(5)
    f = <<0x8E, 20::signed-8, -70::signed-8, 1>> <> payload
    assert {[control, discover], _} = rx(f)
    assert control.type == :control_data
    assert control.payload.payload_type == 0x92
    assert discover.type == :discover_response
    assert discover.payload.node_type == 2
    assert discover.payload.snr_in == 2.0
    assert discover.payload.tag == "01020304"
    assert discover.payload.pubkey == String.duplicate("05", 32)
    assert discover.attributes.node_type == 2
  end

  test "rx log data parses the packet header and path" do
    # flood (route 1), payload type 2, 2 hops of 1 byte
    payload = <<0b00_0010_01, 2, 0xAA, 0xBB, 1, 2, 3>>
    f = <<0x88, 20::signed-8, -80::signed-8>> <> payload
    assert %Event{type: :rx_log_data, payload: p, attributes: a} = one(f)
    assert p.snr == 5.0 and p.rssi == -80
    assert p.route_typename == "FLOOD"
    assert p.payload_typename == "TEXT_MSG"
    assert p.path == "aabb" and p.path_len == 2
    assert a.route_type == 1 and a.payload_type == 2 and a.path == "aabb"
  end

  test "rx log with a tiny payload degrades to sentinels" do
    assert %Event{payload: p, attributes: a} = one(<<0x88, 0, 0, 1>>)
    assert p.route_typename == "UNK" and a.payload_type == -1
  end

  test "malformed frames never raise" do
    capture_log(fn ->
      for code <- 0..255, len <- [0, 1, 2, 5, 9, 33] do
        frame = <<code>> <> :binary.copy(<<0xFF>>, len)
        assert {events, %Reader{}} = rx(frame)
        assert is_list(events)
      end

      assert {[], _} = rx(<<>>)
    end)
  end
end
