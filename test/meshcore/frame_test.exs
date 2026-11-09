defmodule Meshcore.FrameTest do
  use ExUnit.Case, async: true
  doctest Meshcore.Frame

  alias Meshcore.Frame

  test "encode prefixes marker and little-endian length" do
    assert Frame.encode(<<1, 2, 3>>) == <<0x3C, 3, 0, 1, 2, 3>>
  end

  test "decodes a frame split across chunks" do
    {[], s} = Frame.decode(Frame.new(), <<0x3E, 4>>)
    {[], s} = Frame.decode(s, <<0, 1, 2>>)
    assert {[<<1, 2, 3, 4>>], _} = Frame.decode(s, <<3, 4>>)
  end

  test "decodes several frames in one chunk" do
    chunk = <<0x3E, 1, 0, 7, 0x3E, 2, 0, 8, 9>>
    assert {[<<7>>, <<8, 9>>], %Frame{buffer: <<>>}} = Frame.decode(Frame.new(), chunk)
  end

  test "skips junk before the start marker" do
    assert {[<<5>>], _} = Frame.decode(Frame.new(), "boot log...\n" <> <<0x3E, 1, 0, 5>>)
  end

  test "drops chunks without a start marker" do
    assert {[], %Frame{buffer: <<>>}} = Frame.decode(Frame.new(), "just text")
  end

  test "resynchronises after an oversized length" do
    bad = <<0x3E, 0xFF, 0xFF>>
    good = <<0x3E, 1, 0, 9>>
    assert {[<<9>>], _} = Frame.decode(Frame.new(), bad <> good)
  end

  test "ignores empty frames" do
    assert {[<<1>>], _} = Frame.decode(Frame.new(), <<0x3E, 0, 0, 0x3E, 1, 0, 1>>)
  end
end
