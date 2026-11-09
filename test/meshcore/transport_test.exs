defmodule Meshcore.TransportTest do
  use ExUnit.Case, async: true
  import Meshcore.Test.Frames

  alias Meshcore.{Commands, Event, Frame}

  defmodule FakeBLE do
    @behaviour Meshcore.Transport.BLE.Adapter
    def connect(transport, opts) do
      test = Keyword.fetch!(opts, :test_pid)
      send(test, {:ble_connect, transport, opts})

      if opts[:fail],
        do: {:error, :not_found},
        else: {:ok, %{transport: transport, test: test, opts: opts}, "AA:BB"}
    end

    def write(%{test: test, transport: t, opts: opts}, frame) do
      send(test, {:ble_write, frame})

      cond do
        opts[:stall] -> Process.sleep(:infinity)
        match?(<<1, 3, _::binary>>, frame) -> send(t, {:ble_data, self_info()})
        true -> :ok
      end

      :ok
    end

    def pair(%{test: test}, pin) do
      send(test, {:ble_pair, pin})
      :ok
    end

    def disconnect(%{test: test}), do: send(test, :ble_disconnect) && :ok
  end

  describe "TCP" do
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()

      server =
        spawn_link(fn ->
          {:ok, sock} = :gen_tcp.accept(listen)
          send(parent, {:server_sock, sock})
          serve(sock, Frame.new())
        end)

      %{port: port, server: server, listen: listen}
    end

    defp serve(sock, state) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, data} ->
          # device-side framing is mirrored: client frames start with 0x3C
          for <<0x3C, len::little-16, payload::binary-size(len) <- data>> do
            reply =
              case payload do
                <<1, 3, _::binary>> -> self_info()
                <<0x14>> -> <<12, 3900::little-16>>
                _ -> nil
              end

            if reply, do: :gen_tcp.send(sock, <<0x3E, byte_size(reply)::little-16>> <> reply)
          end

          serve(sock, state)

        {:error, _} ->
          :ok
      end
    end

    test "end to end over a socket", %{port: port} do
      assert {:ok, mc} = Meshcore.create_tcp("127.0.0.1", port)
      assert Meshcore.self_info(mc).name == "TestNode"
      assert {:ok, %Event{payload: %{level: 3900}}} = Commands.get_bat(mc)
      assert :ok = Meshcore.disconnect(mc)
    end

    test "connection refused is an error tuple" do
      {:ok, l} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(l)
      :gen_tcp.close(l)

      assert {:error, {:connect_failed, _}} =
               Meshcore.create_tcp("127.0.0.1", port, connect_timeout: 500)
    end

    test "server closing the socket is reported as a disconnect", %{port: port} do
      {:ok, mc} = Meshcore.create_tcp("127.0.0.1", port)
      {:ok, _} = Meshcore.subscribe(mc, :disconnected)
      assert_receive {:server_sock, sock}
      :gen_tcp.close(sock)

      assert_receive {:meshcore, _,
                      %Event{type: :disconnected, payload: %{reason: "tcp_disconnect"}}},
                     2_000

      refute Meshcore.connected?(mc)
    end

    test "a one-way link is detected after 5 unanswered sends", %{port: port} do
      {:ok, mc} = Meshcore.create_tcp("127.0.0.1", port)
      {:ok, _} = Meshcore.subscribe(mc, :disconnected)
      Meshcore.set_default_timeout(mc, 20)
      for _ <- 1..7, do: Commands.get_time(mc)

      assert_receive {:meshcore, _,
                      %Event{type: :disconnected, payload: %{reason: "tcp_no_response"}}},
                     2_000
    end
  end

  describe "BLE" do
    test "connects through the adapter, pairs and talks" do
      assert {:ok, mc} =
               Meshcore.create_ble(
                 adapter: FakeBLE,
                 address: "AA:BB",
                 pin: "123456",
                 adapter_opts: [test_pid: self()]
               )

      assert_receive {:ble_pair, "123456"}
      assert_receive {:ble_connect, _, opts}
      assert opts[:service_uuid] == Meshcore.Transport.BLE.uart_service_uuid()
      assert opts[:name_prefix] == "MeshCore"
      assert_receive {:ble_write, <<1, 3, _::binary>>}
      assert Meshcore.self_info(mc).name == "TestNode"
      Meshcore.disconnect(mc)
      assert_receive :ble_disconnect
    end

    test "adapter errors surface as connect errors" do
      assert {:error, {:connect_failed, :not_found}} =
               Meshcore.create_ble(adapter: FakeBLE, adapter_opts: [test_pid: self(), fail: true])
    end

    test "a stalled write tears the link down instead of freezing" do
      {:ok, mc} =
        Meshcore.start_link(
          transport:
            {Meshcore.Transport.BLE,
             adapter: FakeBLE, write_timeout: 100, adapter_opts: [test_pid: self(), stall: true]},
          connect: false
        )

      {:ok, _} = Meshcore.subscribe(mc, :disconnected)
      # the appstart write stalls
      assert {:error, _} = Meshcore.connect(mc)
      refute Meshcore.connected?(mc)
      assert Process.alive?(mc)
    end
  end

  test "serial transport reports a missing port as a connect failure" do
    assert {:error, {:connect_failed, _}} =
             Meshcore.create_serial("/dev/does-not-exist", dtr: true)
  end
end
