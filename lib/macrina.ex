defmodule Macrina do
  def id do
    :crypto.strong_rand_bytes(16) |> :binary.encode_hex()
  end
end
