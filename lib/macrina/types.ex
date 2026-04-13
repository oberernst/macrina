defmodule Macrina.Types do
  @moduledoc """
  Bidirectional codec for CoAP message types.

  Maps between atoms (`:con`, `:non`, `:ack`, `:rst`) and their integer
  wire values (0–3) as defined in RFC 7252, Section 3.
  """
  @types_by_number %{0 => :con, 1 => :non, 2 => :ack, 3 => :rst}
  @numbers_by_type %{con: 0, non: 1, ack: 2, rst: 3, res: 3}

  def valid_type?(type) when is_atom(type) do
    Map.has_key?(@numbers_by_type, type)
  end

  def valid_type?(_type), do: false

  def decode(number) when is_integer(number) do
    Map.fetch(@types_by_number, number)
  end

  def encode(type) when is_atom(type) do
    Map.fetch(@numbers_by_type, type)
  end

  def parse(0), do: :con
  def parse(1), do: :non
  def parse(2), do: :ack
  def parse(3), do: :rst

  def parse(:con), do: 0
  def parse(:non), do: 1
  def parse(:ack), do: 2
  def parse(:rst), do: 3
  def parse(:res), do: 3
end
