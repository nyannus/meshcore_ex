defmodule Meshcore.LppTest do
  use ExUnit.Case, async: true
  alias Meshcore.Lpp

  test "negative current wraps like the Python reference" do
    assert {:ok, [%{channel: 2, type: "current", value: -0.011}]} =
             Lpp.parse(<<2, 117, 0xFF, 0xF5>>)
  end

  test "positive current" do
    assert {:ok, [%{type: "current", value: 0.5}]} = Lpp.parse(<<2, 117, 0x01, 0xF4>>)
  end

  test "direction is a scalar" do
    assert {:ok, [%{type: "direction", value: 90}]} = Lpp.parse(<<2, 132, 0x00, 0x5A>>)
  end

  test "temperature, humidity, voltage" do
    buf = <<1, 103, 0x00, 0xE1>> <> <<1, 104, 0x64>> <> <<2, 116, 0x01, 0x90>>

    assert {:ok,
            [
              %{type: "temperature", value: 22.5},
              %{type: "humidity", value: 50.0},
              %{type: "voltage", value: 4.0}
            ]} = Lpp.parse(buf)
  end

  test "gps decodes to a map" do
    lat = round(48.1234 * 10_000)
    lon = round(11.5678 * 10_000)
    alt = 51_200

    assert {:ok, [%{type: "gps", value: %{latitude: la, longitude: lo, altitude: al}}]} =
             Lpp.parse(<<3, 136, lat::big-signed-24, lon::big-signed-24, alt::big-signed-24>>)

    assert_in_delta la, 48.1234, 1.0e-6
    assert_in_delta lo, 11.5678, 1.0e-6
    assert_in_delta al, 512.0, 1.0e-6
  end

  test "accelerometer has named axes, gyrometer a list" do
    acc = <<1, 113, 10::big-signed-16, 20::big-signed-16, -10::big-signed-16>>
    assert {:ok, [%{value: %{acc_x: 0.01, acc_y: 0.02, acc_z: -0.01}}]} = Lpp.parse(acc)
    gyro = <<1, 134, 100::big-signed-16, 200::big-signed-16, 0::big-signed-16>>
    assert {:ok, [%{type: "gyrometer", value: [1.0, 2.0, +0.0]}]} = Lpp.parse(gyro)
  end

  test "stops at a zero channel byte" do
    assert {:ok, [%{channel: 1}]} = Lpp.parse(<<1, 103, 0, 10, 0, 0, 0, 0>>)
  end

  test "unknown types and truncated data are errors, not crashes" do
    assert {:error, {:unknown_lpp_type, 99}} = Lpp.parse(<<1, 99, 0>>)
    assert {:error, :truncated} = Lpp.parse(<<1, 103, 0>>)
  end

  test "mma records" do
    buf = <<1, 103, 100::big-16, 200::big-16, 150::big-16, 0>>

    assert {:ok, [%{channel: 1, type: "temperature", min: 10.0, max: 20.0, avg: 15.0}]} =
             Lpp.parse_mma(buf)
  end
end
