defmodule Macrina.Message.Opts do
  @moduledoc false

  # CoAP option number/name registry (RFC 7252 §5.10).
  #
  # Wave C swapped the original `Enum.find/2` linear scan for compile-time
  # maps. Lookups are now O(log n) on map size and the option list is closed:
  # callers cannot register new options at runtime (none ever did).

  @opts [
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

  @number_to_name Map.new(@opts)
  @name_to_number Map.new(@opts, fn {number, name} -> {name, number} end)

  @spec name(integer()) :: String.t() | nil
  def name(number) when is_integer(number) do
    Map.get(@number_to_name, number)
  end

  @spec number(String.t()) :: integer() | nil
  def number(name) when is_binary(name) do
    Map.get(@name_to_number, name)
  end

  @spec atom_name(integer()) :: atom() | nil
  def atom_name(number) do
    case name(number) do
      nil -> nil
      string -> to_atom(string)
    end
  end

  @spec to_atom(String.t()) :: atom()
  def to_atom(name) when is_binary(name) do
    name |> String.downcase() |> String.replace("-", "_") |> String.to_atom()
  end
end
