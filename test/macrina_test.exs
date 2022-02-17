defmodule MacrinaTest do
  use ExUnit.Case
  doctest Macrina

  test "greets the world" do
    assert Macrina.hello() == :world
  end
end
