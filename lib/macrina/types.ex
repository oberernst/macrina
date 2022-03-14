defmodule Macrina.Types do
  def parse(0), do: :con
  def parse(1), do: :non
  def parse(2), do: :ack
  def parse(3), do: :res

  def parse(:con), do: 0
  def parse(:non), do: 1
  def parse(:ack), do: 2
  def parse(:res), do: 3
end
