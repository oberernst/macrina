defmodule Macrina.Message.Opts do
  @opts [
    {1, "If-Match"},
    {3, "Uri-Host"},
    {4, "ETag"},
    {5, "If-None-Match"},
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
    {35, "Proxy-Uri"},
    {39, "Proxy-Scheme"},
    {60, "Size1"}
  ]

  def atom_name(number) do
    number |> name() |> to_atom()
  end

  def name(number) do
    case Enum.find(@opts, fn {n, _} -> n == number end) do
      {_, name} -> name
      nil -> nil
    end
  end

  def number(name) do
    case Enum.find(@opts, fn {_, n} -> n == name end) do
      {number, _} -> number
      nil -> nil
    end
  end

  def to_atom(name) do
    name |> String.downcase() |> String.replace("-", "_") |> String.to_atom()
  end
end
