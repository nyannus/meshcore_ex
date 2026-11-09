defmodule Meshcore.UtilTest do
  use ExUnit.Case, async: true
  doctest Meshcore.Event
  alias Meshcore.Util

  @key :binary.copy(<<0xAB>>, 32)
  @hex String.duplicate("ab", 32)

  test "to_key accepts raw, hex and contact destinations" do
    assert Util.to_key(@key, 6) == binary_part(@key, 0, 6)
    assert Util.to_key(@hex, 6) == binary_part(@key, 0, 6)
    assert Util.to_key(@hex, 32) == @key
    assert Util.to_key(%{public_key: @hex}, 32) == @key
  end

  test "to_key rejects malformed input" do
    assert_raise ArgumentError, fn -> Util.to_key("ab", 6) end
    assert_raise ArgumentError, fn -> Util.to_key(%{}, 6) end
    assert_raise ArgumentError, fn -> Util.to_key(%{public_key: "zz"}, 6) end
    assert_raise ArgumentError, fn -> Util.to_key(42, 6) end
    assert_raise ArgumentError, fn -> Util.to_key(%{public_key: "abcd"}, 6) end
  end

  test "utf8 drops invalid bytes" do
    assert Util.utf8(<<"he", 0xFF, "llo">>) == "hello"
    assert Util.utf8("héllo") == "héllo"
    assert Util.cstr(<<"ab", 0, 0>>) == "ab"
  end

  test "split_path_len" do
    assert Util.split_path_len(255) == {-1, -1}
    assert Util.split_path_len(0b01_000011) == {1, 3}
  end
end
