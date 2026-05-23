defmodule Macrina.Peer.Block1Server do
  @moduledoc false

  # Pure Block1 (RFC 7959 §2.5) server-side ingest. Decides what should
  # happen for each incoming Block1 message — store it and ask for the
  # next one, surface a streaming chunk to the router, hand a fully
  # assembled payload to the router, or reject the upload — and returns
  # the updated exchange alongside the decision. All UDP I/O, handler
  # invocation, telemetry, and dedup caching stay in
  # `Macrina.Peer.Session`, which interprets the decision.

  alias Macrina.{Block1, Blockwise, Exchange, Message}
  alias Macrina.Block1.Chunk
  alias Macrina.Message.Opts.Block

  @type decision ::
          {:continue, Block.t()}
          | {:assembled, binary(), Block.t()}
          | {:incomplete, Block.t()}
          | {:too_large, Block.t()}
          | {:stream_chunk, Chunk.t(), Block.t()}

  @doc """
  Decides how to handle a Block1 message against the current policy and
  exchange state. Returns `{decision, next_exchange}`. The caller is
  responsible for any handler invocation, telemetry, and reply
  transmission implied by the decision.
  """
  @spec ingest(Block1.t(), Exchange.t(), Message.t()) :: {decision(), Exchange.t()}
  def ingest(%Block1{} = policy, %Exchange{} = exchange, %Message{} = message) do
    case Exchange.store_block(exchange, message) do
      {:ok, next_exchange} ->
        if transfer_too_large?(policy, next_exchange, message) do
          {{:too_large, response_block(policy, message)}, next_exchange}
        else
          {decide(policy, next_exchange, message), next_exchange}
        end

      {:error, _reason} ->
        {{:incomplete, response_block(policy, message)}, exchange}
    end
  end

  @doc """
  Returns the Block1 control block Macrina echoes back to a client on a
  reply to an incoming Block1 message — the same block number with
  `more: false` and the negotiated block size (the policy's preferred
  size, capped by the client's requested size).
  """
  @spec response_block(Block1.t(), Message.t()) :: Block.t() | nil
  def response_block(%Block1{} = policy, %Message{descriptive_block: %Block{} = block}) do
    %Block{number: block.number, more: false, size: negotiated_size(policy, block)}
  end

  def response_block(%Block1{}, %Message{}), do: nil

  defp decide(%Block1{mode: :streaming} = policy, exchange, message) do
    case Blockwise.transfer(exchange.blocks, message) do
      {:ok, transfer} ->
        chunk = Chunk.from_message(message, transfer)
        {:stream_chunk, chunk, response_block(policy, message)}

      :error ->
        {:incomplete, response_block(policy, message)}
    end
  end

  defp decide(
         %Block1{mode: :atomic} = policy,
         _exchange,
         %Message{
           descriptive_block: %Block{more: true}
         } = message
       ) do
    {:continue, response_block(policy, message)}
  end

  defp decide(
         %Block1{mode: :atomic} = policy,
         exchange,
         %Message{
           descriptive_block: %Block{more: false}
         } = message
       ) do
    case Blockwise.assemble(exchange.blocks, message) do
      {:ok, payload, _stats} ->
        {:assembled, payload, response_block(policy, message)}

      {:error, :missing_block, _stats} ->
        {:incomplete, response_block(policy, message)}

      :error ->
        {:incomplete, response_block(policy, message)}
    end
  end

  defp transfer_too_large?(%Block1{max_body_size: :infinity}, _exchange, _message), do: false

  defp transfer_too_large?(%Block1{max_body_size: limit}, exchange, message)
       when is_integer(limit) and limit >= 0 do
    case Blockwise.transfer(exchange.blocks, message) do
      {:ok, %{bytes: bytes}} -> bytes > limit
      :error -> false
    end
  end

  defp negotiated_size(%Block1{preferred_block_size: preferred}, %Block{size: requested})
       when is_integer(preferred) and preferred > 0 do
    min(preferred, requested)
  end

  defp negotiated_size(%Block1{}, %Block{size: requested}), do: requested
end
