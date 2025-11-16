defmodule RamaxTest do
  use ExUnit.Case
  doctest Ramax

  test "greets the world" do
    assert Ramax.hello() == :world
  end
end
