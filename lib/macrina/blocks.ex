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
  def read(acc) when acc == %{}, do: {:error, {:missing, 0}}

  def read(acc) do
    sorted = Enum.sort_by(acc, &elem(&1, 0), :asc)

    Enum.reduce_while(sorted, {-1, <<>>}, fn {num, chunk}, {last, payload} ->
      if num == last + 1 do
        {:cont, {num, payload <> chunk}}
      else
        {:halt, {:missing, last + 1}}
      end
    end)
    |> case do
      {_last, payload} when is_binary(payload) -> {:ok, payload}
      {:missing, n} -> {:error, {:missing, n}}
    end
  end
end
