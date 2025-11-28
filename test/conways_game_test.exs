defmodule ConwaysGameTest do
  use ExUnit.Case
  doctest ConwaysGame

  test "greets the world" do
    assert ConwaysGame.hello() == :world
  end
end
