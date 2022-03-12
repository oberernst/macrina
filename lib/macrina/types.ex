defmodule Macrina.Types do
  def parse(0), do: :confirmable
  def parse(1), do: :non_confirmable
  def parse(2), do: :acknowledgement
  def parse(3), do: :reset

  def parse(:confirmable), do: 0
  def parse(:non_confirmable), do: 1
  def parse(:acknowledgement), do: 2
  def parse(:reset), do: 3
end
