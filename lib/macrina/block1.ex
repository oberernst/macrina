defmodule Macrina.Block1 do
  @moduledoc """
  Public server-side policy for CoAP `Block1` uploads.

    This policy controls how large an upload may become before the server rejects
    it, what block size is acknowledged back to the client during `Block1`
    negotiation, and whether handlers receive uploads atomically or chunk-by-chunk.
  """

  @valid_modes [:atomic, :streaming]
  @valid_block_sizes [16, 32, 64, 128, 256, 512, 1024]

  defstruct max_body_size: :infinity, mode: :atomic, preferred_block_size: nil

  @type t :: %__MODULE__{
          max_body_size: non_neg_integer() | :infinity,
          mode: :atomic | :streaming,
          preferred_block_size: pos_integer() | nil
        }

  @type new_error ::
          {:invalid_max_body_size, term()}
          | {:invalid_mode, term()}
          | {:invalid_preferred_block_size, term()}
          | :invalid_policy

  def new(opts \\ [])

  def new(%__MODULE__{} = policy) do
    validate_policy(policy)
  end

  def new(opts) when is_list(opts) do
    policy = %__MODULE__{
      max_body_size: Keyword.get(opts, :max_body_size, :infinity),
      mode: Keyword.get(opts, :mode, :atomic),
      preferred_block_size: Keyword.get(opts, :preferred_block_size)
    }

    validate_policy(policy)
  end

  def new(_opts) do
    {:error, :invalid_policy}
  end

  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid Block1 policy: #{inspect(reason)}"
    end
  end

  def to_connection_opts(%__MODULE__{} = policy) do
    [
      block1_max_body_size: policy.max_body_size,
      block1_mode: policy.mode,
      block1_preferred_block_size: policy.preferred_block_size
    ]
  end

  defp validate_policy(%__MODULE__{} = policy) do
    with :ok <- validate_max_body_size(policy.max_body_size),
         :ok <- validate_mode(policy.mode),
         :ok <- validate_preferred_block_size(policy.preferred_block_size) do
      {:ok, policy}
    end
  end

  defp validate_mode(mode) when mode in @valid_modes do
    :ok
  end

  defp validate_mode(mode) do
    {:error, {:invalid_mode, mode}}
  end

  defp validate_max_body_size(:infinity) do
    :ok
  end

  defp validate_max_body_size(max_body_size)
       when is_integer(max_body_size) and max_body_size >= 0 do
    :ok
  end

  defp validate_max_body_size(max_body_size) do
    {:error, {:invalid_max_body_size, max_body_size}}
  end

  defp validate_preferred_block_size(nil) do
    :ok
  end

  defp validate_preferred_block_size(preferred_block_size)
       when preferred_block_size in @valid_block_sizes do
    :ok
  end

  defp validate_preferred_block_size(preferred_block_size) do
    {:error, {:invalid_preferred_block_size, preferred_block_size}}
  end
end
