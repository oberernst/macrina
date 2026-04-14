defmodule Macrina.Types do
  @moduledoc false

  # Bidirectional codec for CoAP message types (RFC 7252 §3).
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
end
