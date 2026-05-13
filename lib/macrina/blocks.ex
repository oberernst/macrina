defmodule Macrina.Blocks do
  @moduledoc false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @type acc :: %{non_neg_integer() => binary()}

  @spec empty() :: acc()
  def empty, do: %{}

  @spec push(acc(), Message.t()) :: acc()
  def push(acc, %Message{descriptive_block: %Block{number: number}, payload: payload}) do
    Map.put(acc, number, payload)
  end

  @spec read(acc()) :: {:ok, binary()} | {:error, {:missing, non_neg_integer()}}
  def read(acc) when map_size(acc) == 0, do: {:error, {:missing, 0}}

  def read(acc) do
    expected = 0..(map_size(acc) - 1)

    case Enum.find(expected, &(not Map.has_key?(acc, &1))) do
      nil -> {:ok, Enum.map_join(expected, "", &Map.fetch!(acc, &1))}
      n -> {:error, {:missing, n}}
    end
  end
end
