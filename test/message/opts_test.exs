defmodule Macrina.Message.OptsTest do
  use ExUnit.Case, async: true

  # Direct tests for the CoAP option number/name registry (RFC 7252 §5.10).
  # These pin the contract before Wave C swaps the linear `Enum.find` lookups
  # for compile-time maps.

  alias Macrina.Message.Opts

  @well_known [
    {1, "If-Match"},
    {3, "Uri-Host"},
    {4, "ETag"},
    {5, "If-None-Match"},
    {6, "Observe"},
    {7, "Uri-Port"},
    {8, "Location-Path"},
    {11, "Uri-Path"},
    {12, "Content-Format"},
    {14, "Max-Age"},
    {15, "Uri-Query"},
    {17, "Accept"},
    {20, "Location-Query"},
    {23, "Block2"},
    {27, "Block1"},
    {28, "Size2"},
    {35, "Proxy-Uri"},
    {39, "Proxy-Scheme"},
    {60, "Size1"}
  ]

  describe "name/1" do
    for {number, name} <- @well_known do
      test "maps option number #{number} to #{inspect(name)}" do
        assert Opts.name(unquote(number)) == unquote(name)
      end
    end

    test "returns nil for an unregistered number" do
      # 0 and 2 are reserved/unused; 100 is well outside the registered range.
      assert Opts.name(0) == nil
      assert Opts.name(2) == nil
      assert Opts.name(100) == nil
    end
  end

  describe "number/1" do
    for {number, name} <- @well_known do
      test "maps option name #{inspect(name)} to #{number}" do
        assert Opts.number(unquote(name)) == unquote(number)
      end
    end

    test "returns nil for an unregistered name" do
      assert Opts.number("Not-A-Real-Option") == nil
    end
  end

  describe "atom_name/1" do
    test "downcases and replaces hyphens with underscores" do
      assert Opts.atom_name(11) == :uri_path
      assert Opts.atom_name(12) == :content_format
      assert Opts.atom_name(17) == :accept
    end
  end

  test "name and number are inverses for every registered option" do
    for {number, name} <- @well_known do
      assert Opts.name(Opts.number(name)) == name
      assert Opts.number(Opts.name(number)) == number
    end
  end
end
