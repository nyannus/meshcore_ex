defmodule Meshcore.CommandsTest do
  use ExUnit.Case, async: true
  import Meshcore.Test.Frames

  alias Meshcore.{Commands, Event}
  alias Meshcore.Commands.Base
  alias Meshcore.Test.MockTransport

  @pub String.duplicate("ab", 32)
  @contact %{
    public_key: @pub,
    type: 2,
    flags: 1,
    out_path_len: 2,
    out_path_hash_mode: 0,
    out_path: "aabb",
    adv_name: "Rep",
    last_advert: 10,
    adv_lat: 1.5,
    adv_lon: -2.5
  }

  defp start(responder) do
    handler = fn
      <<1, 3, _::binary>> -> [self_info()]
      frame -> responder.(frame)
    end

    transport = {MockTransport, [test_pid: self(), responder: handler]}
    {:ok, mc} = Meshcore.start_link(transport: transport, connect: false, default_timeout: 500)
    {:ok, _} = Meshcore.connect(mc)
    assert_receive {:mock_transport, device}
    {mc, device}
  end

  defp sent_frames(acc \\ []) do
    receive do
      {:mock_sent, f} -> sent_frames([f | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  describe "encoding" do
    test "set_coords, set_radio, set_channel, flood scope" do
      {mc, _} = start(fn _ -> [ok()] end)

      Commands.set_coords(mc, 48.5, -8.25)
      Commands.set_radio(mc, 869.525, 250, 11, 5)
      Commands.set_radio(mc, 869.525, 250, 11, 5, true)
      Commands.set_channel(mc, 1, "#pub")
      Commands.set_flood_scope(mc, "region")
      Commands.set_flood_scope(mc, "*")
      Commands.set_default_flood_scope(mc, nil)

      [_appstart, coords, radio, radio2, chan, scope, unscoped, dscope] = sent_frames()
      assert coords == <<0x0E, 48_500_000::little-32, -8_250_000::little-signed-32, 0::32>>
      assert radio == <<0x0B, 869_525::little-32, 250_000::little-32, 11, 5>>
      assert radio2 == radio <> <<1>>
      <<0x20, 1, name::binary-32, secret::binary-16>> = chan
      assert String.trim_trailing(name, <<0>>) == "#pub"
      assert secret == binary_part(:crypto.hash(:sha256, "#pub"), 0, 16)
      assert scope == <<54, 0>> <> binary_part(:crypto.hash(:sha256, "#region"), 0, 16)
      assert unscoped == <<54, 1>>
      assert dscope == <<63>>
    end

    test "argument validation raises ArgumentError" do
      {mc, _} = start(fn _ -> [ok()] end)
      assert_raise ArgumentError, fn -> Commands.set_channel(mc, 1, "x", <<1, 2>>) end
      assert_raise ArgumentError, fn -> Commands.send_raw_data(mc, <<1, 2>>) end
      assert_raise ArgumentError, fn -> Commands.send_channel_data(mc, 0, 0, <<>>) end
      assert_raise ArgumentError, fn -> Commands.send_msg(mc, "zz", "hi") end
    end

    test "send_trace pads, derives flags and validates the path" do
      {mc, _} = start(fn _ -> [msg_sent()] end)
      assert {:ok, _} = Commands.send_trace(mc, tag: 1, auth_code: 2)
      assert {:ok, _} = Commands.send_trace(mc, tag: 1, auth_code: 2, path: "23,5f")
      assert {:ok, _} = Commands.send_trace(mc, tag: 1, auth_code: 2, path: "2345,5f60")

      assert {:error, %Event{payload: %{reason: :invalid_path_format}}} =
               Commands.send_trace(mc, path: "23,zz")

      [_, empty, one, two] = sent_frames()
      assert empty == <<36, 1::little-32, 2::little-32, 0, 0>>
      assert one == <<36, 1::little-32, 2::little-32, 0, 0x23, 0x5F>>
      assert two == <<36, 1::little-32, 2::little-32, 1, 0x23, 0x45, 0x5F, 0x60>>
    end

    test "send_chan_msg accepts int and 4-byte timestamps, rejects others" do
      {mc, _} = start(fn _ -> [ok()] end)
      assert {:ok, _} = Commands.send_chan_msg(mc, 2, "hi", timestamp: 7)
      assert {:ok, _} = Commands.send_chan_msg(mc, 2, "hi", timestamp: <<7, 0, 0, 0>>)

      assert {:error, %Event{payload: %{reason: :invalid_timestamp_format}}} =
               Commands.send_chan_msg(mc, 2, "hi", timestamp: "x")

      [_, a, b] = sent_frames()
      assert a == b
      assert a == <<3, 0, 2, 7::little-32, "hi">>
    end

    test "update_contact encodes the full contact record and updates the mirror" do
      list = fn
        <<4>> ->
          [
            contact_start(1),
            contact(<<0xAB::8>> |> :binary.copy(32), "Rep", plen: 2, path: <<0xAA, 0xBB>>),
            contact_end(1)
          ]

        <<9, _::binary>> ->
          [ok()]

        _ ->
          []
      end

      {mc, _} = start(list)
      {:ok, _} = Commands.get_contacts(mc)
      contact = Meshcore.get_contact_by_name(mc, "Rep")
      assert {:ok, _} = Commands.change_contact_flags(mc, contact, 5)
      assert Meshcore.get_contact_by_name(mc, "Rep").flags == 5

      assert {:ok, _} = Commands.change_contact_path(mc, contact, "ccdd:0")
      assert %{out_path: "ccdd", out_path_len: 2} = Meshcore.get_contact_by_name(mc, "Rep")

      frames = sent_frames()
      [_, _list, flags_frame, path_frame] = frames

      <<9, key::binary-32, type, flags, plen, path::binary-64, name::binary-32, _la::little-32,
        _::binary>> = flags_frame

      assert key == :binary.copy(<<0xAB>>, 32) and type == 1 and flags == 5 and plen == 2
      assert binary_part(path, 0, 2) == <<0xAA, 0xBB>>
      assert String.trim_trailing(name, <<0>>) == "Rep"
      <<9, _::binary-32, _, _, _, path2::binary-64, _::binary>> = path_frame
      assert binary_part(path2, 0, 2) == <<0xCC, 0xDD>>
    end
  end

  describe "factory reset" do
    test "needs the matching token" do
      {mc, _} = start(fn _ -> [ok()] end)
      assert {:error, :invalid_token} = Commands.confirm_factory_reset(mc, "nope")
      {:ok, token} = Commands.request_factory_reset(mc)
      assert {:error, :invalid_token} = Commands.confirm_factory_reset(mc, "wrong")
      # a failed attempt consumes the token
      assert {:error, :invalid_token} = Commands.confirm_factory_reset(mc, token)
      {:ok, token} = Commands.request_factory_reset(mc)
      assert {:ok, _} = Commands.confirm_factory_reset(mc, token)
    end
  end

  describe "signing" do
    test "streams chunks and returns the signature" do
      responder = fn
        <<33>> -> [<<19, 0, 8192::little-32>>]
        <<34, _::binary>> -> [ok()]
        <<35>> -> [<<20, 1, 2, 3>>]
      end

      {mc, _} = start(responder)

      assert {:ok, %Event{type: :signature, payload: %{signature: <<1, 2, 3>>}}} =
               Commands.sign(mc, :binary.copy("x", 250), chunk_size: 100)

      chunks = for <<34, c::binary>> <- sent_frames(), do: byte_size(c)
      assert chunks == [100, 100, 50]
    end

    test "rejects data larger than the device buffer" do
      {mc, _} = start(fn <<33>> -> [<<19, 0, 4::little-32>>] end)
      assert {:error, %Event{payload: %{reason: :data_too_large}}} = Commands.sign(mc, "12345")
    end
  end

  describe "send_msg_with_retry" do
    test "returns as soon as the ack arrives" do
      {mc, device} =
        start(fn
          <<2, _::binary>> -> [msg_sent(<<1, 1, 1, 1>>, 0, 1000)]
          _ -> []
        end)

      spawn(fn ->
        Process.sleep(50)
        MockTransport.push(device, ack(<<1, 1, 1, 1>>))
      end)

      assert {:ok, %Event{payload: %{expected_ack: <<1, 1, 1, 1>>}}} =
               Commands.send_msg_with_retry(mc, @contact, "hi")

      assert [_, <<2, 0, 0, _::binary>>] = sent_frames()
    end

    test "accepts a late ack of an earlier attempt, bumping the attempt number" do
      {:ok, agent} = Agent.start_link(fn -> 1 end)

      {mc, device} =
        start(fn
          <<2, _::binary>> ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})
            [msg_sent(<<n, n, n, n>>, 0, 40)]

          _ ->
            []
        end)

      spawn(fn ->
        Process.sleep(100)
        MockTransport.push(device, ack(<<1, 1, 1, 1>>))
      end)

      assert {:ok, _} = Commands.send_msg_with_retry(mc, @contact, "hi", timestamp: 9)
      sent = for <<2, 0, attempt, 9::little-32, _::binary>> <- sent_frames(), do: attempt
      assert sent == Enum.to_list(0..(length(sent) - 1))
      assert length(sent) >= 2
    end

    test "gives up after max attempts and resets the path to flood" do
      {mc, _} =
        start(fn
          <<2, _::binary>> -> [msg_sent(<<1, 1, 1, 1>>, 0, 20)]
          <<13, _::binary>> -> [ok()]
          _ -> []
        end)

      assert {:error, :not_acknowledged} =
               Commands.send_msg_with_retry(mc, @contact, "hi", max_attempts: 3)

      frames = sent_frames()
      assert Enum.count(frames, &match?(<<2, _::binary>>, &1)) == 3
      assert <<13, _::binary-32>> = Enum.find(frames, &match?(<<13, _::binary>>, &1))
      # no subscription message left behind in our mailbox
      refute_received {:meshcore, _, _}
    end
  end

  describe "binary requests" do
    test "req_status_sync waits for the response matching the tag" do
      tag = <<9, 8, 7, 6>>

      {mc, device} =
        start(fn
          <<0x32, _::binary>> ->
            [msg_sent(tag, 0, 2000), binary_response(<<0, 0, 0, 0>>, status_body()) |> then(& &1)]

          _ ->
            []
        end)

      # first (wrong tag) answer is ignored, then the right one is pushed
      spawn(fn ->
        Process.sleep(30)
        MockTransport.push(device, binary_response(tag, binary_part(status_body(), 0, 56)))
      end)

      assert {:ok, status} = Commands.req_status_sync(mc, @contact)
      assert status.bat == 4100
      assert status.pubkey_pre == "ababababababab" |> binary_part(0, 12)
      [_, req] = sent_frames()
      assert <<0x32, key::binary-32, 1>> = req
      assert key == :binary.copy(<<0xAB>>, 32)
    end

    test "a response that arrives immediately after msg_sent is not lost" do
      tag = <<9, 8, 7, 6>>

      {mc, _} =
        start(fn
          <<0x32, _::binary>> ->
            [msg_sent(tag, 0, 2000), binary_response(tag, <<1, 103, 0, 225>>)]

          _ ->
            []
        end)

      assert {:ok, [%{type: "temperature", value: 22.5}]} =
               Commands.req_telemetry_sync(mc, @contact)
    end

    test "times out cleanly with an error event" do
      {mc, _} =
        start(fn
          <<0x32, _::binary>> -> [msg_sent(<<1, 2, 3, 4>>, 0, 10)]
          _ -> []
        end)

      assert {:error, %Event{payload: %{reason: :timeout}}} =
               Commands.req_acl_sync(mc, @contact, timeout: 50)
    end

    test "neighbours request frame and fetch_all_neighbours paging" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      {mc, _} =
        start(fn
          <<0x32, _::binary-32, 6, _ver, _count, offset::little-16, _order, 2, _rand::binary>> ->
            n = Agent.get_and_update(agent, &{&1, &1 + 1})
            tag = <<n, 0, 0, 0>>

            entry = fn k -> <<k, k, 5::little-signed-32, 8::signed-8>> end

            body =
              if offset == 0,
                do: <<3::little-signed-16, 2::little-signed-16>> <> entry.(1) <> entry.(2),
                else: <<3::little-signed-16, 1::little-signed-16>> <> entry.(3)

            [msg_sent(tag, 0, 20), binary_response(tag, body)]

          _ ->
            []
        end)

      assert {:ok, res} = Commands.fetch_all_neighbours(mc, @contact, pubkey_prefix_length: 2)
      assert res.neighbours_count == 3 and res.results_count == 3
      assert Enum.map(res.neighbours, & &1.pubkey) == ["0101", "0202", "0303"]
    end

    test "anon request to a flooded known contact pins zero-hop and resets it afterwards" do
      tag = <<5, 5, 5, 5>>
      flood = %{@contact | out_path_len: -1, out_path: ""}
      key = :binary.copy(<<0xAB>>, 32)

      {mc, _} =
        start(fn
          <<4>> ->
            [contact_start(1), contact(key, "Rep", plen: 255), contact_end(1)]

          <<9, _::binary>> ->
            [ok()]

          <<13, _::binary>> ->
            [ok()]

          <<0x39, _::binary>> ->
            [msg_sent(tag, 0, 100), binary_response(tag, tag <> "NodeName\nOwner Bob\0")]

          _ ->
            []
        end)

      {:ok, _} = Commands.get_contacts(mc)
      assert {:ok, %{name: "NodeName", owner: "Owner Bob"}} = Commands.req_owner_sync(mc, flood)

      frames = sent_frames()
      kinds = for <<k, _::binary>> <- frames, do: k
      # 22 = device query to learn the path hash mode before pinning the path
      assert kinds == [1, 4, 22, 9, 0x39, 13]
      assert <<0x39, ^key::binary-32, 2, 0>> = Enum.at(frames, 4)
    end

    test "anon request to an unknown node asks for a zero-hop reply" do
      tag = <<5, 5, 5, 5>>

      {mc, _} =
        start(fn
          <<0x39, _::binary>> -> [msg_sent(tag, 0, 100), binary_response(tag, tag <> "r1,r2\0")]
          _ -> []
        end)

      assert {:ok, "r1,r2"} = Commands.req_regions_sync(mc, @pub)
      assert [_, <<0x39, _::binary-32, 1, 0>>] = sent_frames()
    end
  end

  describe "login and path discovery" do
    test "send_login_sync waits for login_success" do
      {mc, _} =
        start(fn
          <<0x1A, _::binary>> -> [msg_sent(<<1, 2, 3, 4>>, 0, 100), <<0x85, 1, 1, 2, 3, 4, 5, 6>>]
          _ -> []
        end)

      assert {:ok, %Event{type: :login_success, payload: %{is_admin: true}}} =
               Commands.send_login_sync(mc, @contact, "pw")

      assert [_, <<0x1A, _::binary-32, "pw">>] = sent_frames()
    end

    test "login timeout and send failure are errors" do
      {mc, _} =
        start(fn
          <<0x1A, _::binary>> -> [msg_sent(<<1, 2, 3, 4>>, 0, 10)]
          _ -> []
        end)

      assert {:error, %Event{payload: %{reason: :timeout}}} =
               Commands.send_login_sync(mc, @contact, "pw", timeout: 40)

      {mc, _} =
        start(fn
          <<0x1A, _::binary>> -> [error(2)]
          _ -> []
        end)

      assert {:error, %Event{payload: %{error_code: 2}}} =
               Commands.send_login_sync(mc, @contact, "pw")
    end

    test "path discovery" do
      {mc, _} =
        start(fn
          <<0x34, _::binary>> ->
            [msg_sent(<<1, 2, 3, 4>>, 0, 100), <<0x8D, 0, 1, 2, 3, 4, 5, 6, 1, 0xAA, 1, 0xBB>>]

          _ ->
            []
        end)

      assert {:ok, %Event{type: :path_response, payload: %{out_path: "aa", in_path: "bb"}}} =
               Commands.send_path_discovery_sync(mc, @contact)
    end
  end

  describe "node discovery" do
    test "adds the tag to the ok payload" do
      {mc, _} = start(fn _ -> [ok()] end)

      assert {:ok, %Event{payload: %{tag: 77}}} =
               Commands.send_node_discover_req(mc, 4, tag: 77, since: 5)

      assert [_, <<55, 0x81, 4, 77::little-32, 5::little-32>>] = sent_frames()
    end
  end

  describe "encode_reply_path/3" do
    test "reverses by hop and packs the hash mode" do
      assert Base.encode_reply_path(3, "aabbcc", 0) == <<3, 0xCC, 0xBB, 0xAA>>
      assert Base.encode_reply_path(2, "aabbccdd", 1) == <<0b01_000010, 0xCC, 0xDD, 0xAA, 0xBB>>
      assert Base.encode_reply_path(0, "", 0) == <<0>>
      assert Base.encode_reply_path(5, "aabb", 0) == <<2, 0xBB, 0xAA>>
      assert Base.encode_reply_path(1, "aa", 3) == <<0>>
    end
  end

  test "auto message fetching drains the queue" do
    {:ok, agent} = Agent.start_link(fn -> 2 end)

    {mc, device} =
      start(fn
        <<10>> ->
          case Agent.get_and_update(agent, &{&1, max(&1 - 1, 0)}) do
            0 -> [<<10>>]
            _ -> [<<8, 0, 255, 0, 1::little-32, "m">>]
          end

        _ ->
          []
      end)

    {:ok, sub} = Meshcore.subscribe(mc, :channel_msg_recv)
    :ok = Meshcore.start_auto_message_fetching(mc)
    sub_ref = sub.ref
    assert_receive {:meshcore, ^sub_ref, _}, 1_000
    assert_receive {:meshcore, ^sub_ref, _}, 1_000
    MockTransport.push(device, <<0x83>>)
    Process.sleep(100)
    assert Process.alive?(mc)
    :ok = Meshcore.stop_auto_message_fetching(mc)
  end
end
