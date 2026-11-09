defmodule Meshcore.Test.Frames do
  @moduledoc false
  # Builders for device -> client frames.

  def pad(bin, size), do: bin <> :binary.copy(<<0>>, max(size - byte_size(bin), 0))

  def self_info(opts \\ []) do
    name = Keyword.get(opts, :name, "TestNode")
    key = Keyword.get(opts, :key, :binary.copy(<<0xAB>>, 32))

    <<5, 1, 22, 30>> <>
      key <>
      <<48_000_000::little-signed-32, 8_000_000::little-signed-32, 2, 0, 0b00_01_10_00, 1,
        869_525::little-32, 250_000::little-32, 11, 5>> <> name
  end

  def ok, do: <<0>>
  def error(code), do: <<1, code>>

  def msg_sent(ack \\ <<1, 2, 3, 4>>, type \\ 0, timeout \\ 4000),
    do: <<6, type>> <> ack <> <<timeout::little-32>>

  def contact(key, name, opts \\ []) do
    plen = Keyword.get(opts, :plen, 255)
    path = Keyword.get(opts, :path, <<>>)

    <<3>> <>
      key <>
      <<Keyword.get(opts, :type, 1), Keyword.get(opts, :flags, 0), plen>> <>
      pad(path, 64) <>
      pad(name, 32) <>
      <<1_700_000_000::little-32, 48_000_000::little-signed-32, 8_000_000::little-signed-32,
        Keyword.get(opts, :lastmod, 1_700_000_100)::little-32>>
  end

  def contact_start(n), do: <<2, n::little-32>>
  def contact_end(lastmod), do: <<4, lastmod::little-32>>

  def key(n), do: :binary.copy(<<n>>, 32)

  def ack(code, trip \\ 120), do: <<0x82>> <> code <> <<trip::little-32>>

  def binary_response(tag, data), do: <<0x8C, 0>> <> tag <> data

  def status_body(opts \\ []) do
    <<Keyword.get(opts, :bat, 4100)::little-16, 0::little-16, -110::little-signed-16,
      -90::little-signed-16, 10::little-32, 20::little-32, 30::little-32, 40::little-32,
      1::little-32, 2::little-32, 3::little-32, 4::little-32, 0::little-16, 28::little-signed-16,
      5::little-16, 6::little-16, 77::little-32, 9::little-32>>
  end
end
