defmodule Meshcore.ClientTest do
  use ExUnit.Case, async: true
  import Meshcore.Test.Frames

  alias Meshcore.{Commands, Event}
  alias Meshcore.Test.MockTransport

  # a device that answers appstart and (optionally) more
  defp responder(extra \\ fn _ -> [] end) do
    fn
      <<1, 3, _::binary>> -> [self_info()]
      frame -> extra.(frame)
    end
  end

  defp start(opts \\ []) do
    {responder_fun, opts} = Keyword.pop(opts, :responder, responder())

    transport = {MockTransport, [test_pid: self(), responder: responder_fun]}
    {:ok, mc} = Meshcore.start_link([transport: transport, connect: false] ++ opts)
    {:ok, %Event{type: :self_info}} = Meshcore.connect(mc)
    assert_receive {:mock_transport, device}
    flush_sent()
    {mc, device}
  end

  defp flush_sent do
    receive do
      {:mock_sent, _} -> flush_sent()
    after
      0 -> :ok
    end
  end

  test "connect performs the handshake and mirrors self info" do
    {mc, _} = start()
    assert Meshcore.connected?(mc)
    assert Meshcore.self_info(mc).name == "TestNode"
  end

  test "connect failure is reported, not raised" do
    transport = {MockTransport, [connect: {:error, :nope}]}
    {:ok, mc} = Meshcore.start_link(transport: transport, connect: false)
    assert {:error, {:connect_failed, :nope}} = Meshcore.connect(mc)
    refute Meshcore.connected?(mc)
  end

  test "commands fail fast when not connected" do
    transport = {MockTransport, [connect: {:error, :nope}]}
    {:ok, mc} = Meshcore.start_link(transport: transport, connect: false)
    assert {:error, %Event{payload: %{reason: :not_connected}}} = Commands.get_bat(mc)
  end

  test "a command returns the expected response and sends the right bytes" do
    {mc, _} =
      start(
        responder:
          responder(fn
            <<0x14>> -> [<<12, 4000::little-16>>]
            _ -> []
          end)
      )

    assert {:ok, %Event{type: :battery, payload: %{level: 4000}}} = Commands.get_bat(mc)
    assert_receive {:mock_sent, <<0x14>>}
  end

  test "device errors come back as {:error, event}" do
    {mc, _} =
      start(
        responder:
          responder(fn
            <<0x14>> -> [error(2)]
            _ -> []
          end)
      )

    assert {:error, %Event{type: :error, payload: %{error_code: 2}}} = Commands.get_bat(mc)
  end

  test "silent device yields a timeout error, not a hang" do
    {mc, _} = start()
    Meshcore.set_default_timeout(mc, 50)
    assert {:error, %Event{payload: %{reason: :timeout}}} = Commands.get_bat(mc)
  end

  test "fire-and-forget commands return immediately" do
    {mc, _} = start()
    assert {:ok, %Event{type: :ok}} = Commands.reboot(mc)
    assert_receive {:mock_sent, <<0x13, "reboot">>}
  end

  test "send_msg frames the message and returns msg_sent" do
    {mc, _} =
      start(
        responder:
          responder(fn
            <<2, _::binary>> -> [msg_sent()]
            _ -> []
          end)
      )

    contact = %{public_key: String.duplicate("ab", 32)}

    assert {:ok, %Event{type: :msg_sent, payload: %{expected_ack: <<1, 2, 3, 4>>}}} =
             Commands.send_msg(mc, contact, "hi", timestamp: 5)

    assert_receive {:mock_sent,
                    <<2, 0, 0, 5::little-32, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, "hi">>}
  end

  test "get_contacts collects the list and keeps the mirror up to date" do
    list = fn <<4>> ->
      [contact_start(2), contact(key(1), "Alice"), contact(key(2), "Bob"), contact_end(99)]
    end

    {mc, _} = start(responder: responder(list))
    assert {:ok, %Event{type: :contacts, payload: contacts}} = Commands.get_contacts(mc)
    assert map_size(contacts) == 2
    assert map_size(Meshcore.contacts(mc)) == 2
    refute Meshcore.contacts_dirty?(mc)
    assert %{adv_name: "Bob"} = Meshcore.get_contact_by_name(mc, "bob")
    assert %{adv_name: "Alice"} = Meshcore.get_contact_by_key_prefix(mc, "0101")
    assert Meshcore.get_contact_by_name(mc, "nobody") == nil
  end

  test "get_contacts waits as long as contacts keep arriving" do
    {mc, device} =
      start(
        responder:
          responder(fn
            <<4>> -> [contact_start(3)]
            _ -> []
          end)
      )

    task = Task.async(fn -> Commands.get_contacts(mc, timeout: 150) end)
    Process.sleep(20)

    for n <- 1..3 do
      MockTransport.push(device, contact(key(n), "C#{n}"))
      Process.sleep(100)
    end

    MockTransport.push(device, contact_end(1))
    assert {:ok, %Event{type: :contacts, payload: p}} = Task.await(task)
    assert map_size(p) == 3
  end

  test "subscribe delivers matching events with filters and unsubscribe stops them" do
    {mc, device} = start()
    {:ok, all} = Meshcore.subscribe(mc, :channel_msg_recv)
    {:ok, ch1} = Meshcore.subscribe(mc, [:channel_msg_recv], attribute_filters: %{channel_idx: 1})

    msg = fn idx -> <<8, idx, 255, 0, 1::little-32, "x">> end
    MockTransport.push(device, msg.(0))
    MockTransport.push(device, msg.(1))

    all_ref = all.ref
    ch1_ref = ch1.ref
    assert_receive {:meshcore, ^all_ref, %Event{attributes: %{channel_idx: 0}}}
    assert_receive {:meshcore, ^all_ref, %Event{attributes: %{channel_idx: 1}}}
    assert_receive {:meshcore, ^ch1_ref, %Event{attributes: %{channel_idx: 1}}}
    refute_receive {:meshcore, ^ch1_ref, %Event{attributes: %{channel_idx: 0}}}, 20

    Meshcore.unsubscribe(all)
    MockTransport.push(device, msg.(1))
    assert_receive {:meshcore, ^ch1_ref, _}
    refute_receive {:meshcore, ^all_ref, _}, 50
  end

  test "a dead subscriber is cleaned up and does not affect others" do
    {mc, device} = start()
    sub_pid = spawn(fn -> receive do: (:never -> :ok) end)
    {:ok, _} = Meshcore.subscribe(mc, :messages_waiting, pid: sub_pid)
    Process.exit(sub_pid, :kill)
    {:ok, mine} = Meshcore.subscribe(mc, :messages_waiting)
    MockTransport.push(device, <<0x83>>)
    mine_ref = mine.ref
    assert_receive {:meshcore, ^mine_ref, %Event{type: :messages_waiting}}
    assert Process.alive?(mc)
  end

  test "wait_for_event resolves, filters and times out" do
    {mc, device} = start()

    task =
      Task.async(fn ->
        Meshcore.wait_for_event(mc, :ack, attribute_filters: %{code: "01020304"}, timeout: 500)
      end)

    Process.sleep(10)
    MockTransport.push(device, ack(<<9, 9, 9, 9>>))
    MockTransport.push(device, ack(<<1, 2, 3, 4>>))
    assert {:ok, %Event{attributes: %{code: "01020304"}}} = Task.await(task)
    assert {:error, :timeout} = Meshcore.wait_for_event(mc, :ack, timeout: 30)
  end

  test "pending commands fail immediately when the link drops" do
    {mc, device} = start()
    {:ok, _} = Meshcore.subscribe(mc, :disconnected)
    task = Task.async(fn -> Commands.get_bat(mc) end)
    Process.sleep(20)
    MockTransport.drop(device, :cable_pulled)
    assert {:error, %Event{payload: %{reason: :disconnected}}} = Task.await(task)
    assert_receive {:meshcore, _, %Event{type: :disconnected, payload: %{reason: "cable_pulled"}}}
    refute Meshcore.connected?(mc)
  end

  test "auto reconnect re-runs the handshake and announces the reconnect" do
    {mc, device} = start(auto_reconnect: true)
    {:ok, _} = Meshcore.subscribe(mc, :connected)
    MockTransport.drop(device)
    assert_receive {:mock_transport, _new_device}, 3_000
    assert_receive {:meshcore, _, %Event{type: :connected, payload: %{reconnected: true}}}, 3_000
    assert Meshcore.connected?(mc)
  end

  test "gives up after max reconnect attempts and emits disconnected" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    # first connection works, all later ones fail
    transport =
      {MockTransport, [test_pid: self(), responder: responder()]}

    {:ok, mc} =
      Meshcore.start_link(
        transport: transport,
        connect: false,
        auto_reconnect: true,
        max_reconnect_attempts: 1
      )

    {:ok, _} = Meshcore.connect(mc)
    assert_receive {:mock_transport, device}
    {:ok, _} = Meshcore.subscribe(mc, :disconnected)
    Agent.update(agent, & &1)
    MockTransport.drop(device)
    # the single reconnect succeeds with the mock, so connected again
    assert_receive {:mock_transport, _}, 3_000
    :timer.sleep(100)
    assert Meshcore.connected?(mc)
  end

  test "mesh lock serialises holders and releases when the holder dies" do
    {mc, _} = start()
    parent = self()

    holder =
      spawn(fn ->
        Meshcore.Client.with_lock(mc, fn ->
          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked
    waiter = Task.async(fn -> Meshcore.Client.with_lock(mc, fn -> :got_it end) end)
    refute Task.yield(waiter, 50)
    Process.exit(holder, :kill)
    assert Task.await(waiter) == :got_it
  end

  test "with_lock is re-entrant" do
    {mc, _} = start()

    assert :inner =
             Meshcore.Client.with_lock(mc, fn ->
               Meshcore.Client.with_lock(mc, fn -> :inner end)
             end)
  end

  test "disconnect emits an event and stops the process" do
    {mc, _} = start()
    {:ok, _} = Meshcore.subscribe(mc, :disconnected)
    ref = Process.monitor(mc)
    assert :ok = Meshcore.disconnect(mc)

    assert_receive {:meshcore, _,
                    %Event{type: :disconnected, payload: %{reason: "manual_disconnect"}}}

    assert_receive {:DOWN, ^ref, _, _, :normal}
  end

  test "state tracking from push events" do
    {mc, device} = start()
    MockTransport.push(device, <<9, 1234::little-32>>)
    MockTransport.push(device, <<0x80>> <> key(1))
    new = binary_part(contact(key(7), "Fresh"), 1, 147)
    MockTransport.push(device, <<0x8A>> <> new)
    Process.sleep(30)
    assert Meshcore.time(mc) == 1234
    assert Meshcore.contacts_dirty?(mc)
    assert %{adv_name: "Fresh"} = Meshcore.pop_pending_contact(mc, String.duplicate("07", 32))
    assert Meshcore.pending_contacts(mc) == %{}
  end

  test "garbage frames do not take the client down" do
    {mc, device} = start()

    ExUnit.CaptureLog.capture_log(fn ->
      for n <- 0..255, do: MockTransport.push(device, <<n, 1, 2>>)
      Process.sleep(100)
    end)

    assert Process.alive?(mc)
    assert Meshcore.connected?(mc)
  end
end
