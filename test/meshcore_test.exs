defmodule MeshcoreTest do
  use ExUnit.Case
  doctest Meshcore

  test "greets the world" do
    assert Meshcore.hello() == :world
  end
end
