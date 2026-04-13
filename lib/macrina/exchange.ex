defmodule Macrina.Exchange do
  @moduledoc """
  Pure protocol state for a single peer exchange lifecycle.

  `Macrina.Connection.Server` owns socket orchestration; this module owns the
  token, message-id, caller, cached-reply, and blockwise tracking that sits
  behind that shell.
  """

  alias Macrina.{Message, Message.Opts.Block, Telemetry}

  defstruct blocks: %{}, callers: [], ids: [], last_reply: {nil, nil}, tokens: []

  @type t :: %__MODULE__{
          blocks: %{optional(non_neg_integer()) => binary()},
          callers: [{binary(), tuple()}],
          ids: [non_neg_integer()],
          last_reply: {binary() | nil, binary() | nil},
          tokens: [binary()]
        }

  def complete_request(%__MODULE__{} = exchange, %Message{} = message) do
    exchange
    |> pop_id(message)
    |> pop_token(message)
  end

  def pop_caller(%__MODULE__{callers: callers} = exchange, caller) do
    %__MODULE__{exchange | callers: List.delete(callers, caller)}
  end

  def pop_caller_for_token(%__MODULE__{} = exchange, token) when is_binary(token) do
    caller = caller_for_token(exchange, token)
    next_exchange = pop_caller(exchange, caller)

    {caller, next_exchange}
  end

  def pop_id(%__MODULE__{ids: ids} = exchange, %Message{id: id}) do
    %__MODULE__{exchange | ids: List.delete(ids, id)}
  end

  def pop_token(%__MODULE__{tokens: tokens} = exchange, %Message{token: token}) do
    %__MODULE__{exchange | tokens: List.delete(tokens, token)}
  end

  def push_block(%__MODULE__{blocks: blocks} = exchange, %Message{
        descriptive_block: %Block{number: num, size: size, more: more},
        payload: payload
      }) do
    next_blocks = Map.put(blocks, num, payload)

    measurements = %{block_number: num, block_size: size, bytes: byte_size(payload)}
    metadata = %{more: more}

    Telemetry.execute([:connection, :block, :received], measurements, metadata)

    %__MODULE__{exchange | blocks: next_blocks}
  end

  def push_caller(%__MODULE__{callers: callers} = exchange, caller) do
    %__MODULE__{exchange | callers: [caller | callers]}
  end

  def push_id(%__MODULE__{ids: ids} = exchange, %Message{id: id}) do
    %__MODULE__{exchange | ids: [id | ids]}
  end

  def push_token(%__MODULE__{tokens: tokens} = exchange, %Message{token: token}) do
    %__MODULE__{exchange | tokens: [token | tokens]}
  end

  def register_request(%__MODULE__{} = exchange, %Message{} = message, from) do
    caller = {message.token, from}

    exchange
    |> push_caller(caller)
    |> push_id(message)
    |> push_token(message)
  end

  @spec read_blocks(t()) :: String.t() | nil
  def read_blocks(%__MODULE__{blocks: blocks}) do
    sorted_blocks = Enum.sort_by(blocks, &elem(&1, 0), :asc)

    # Blockwise assembly only makes sense once we have a contiguous 0..n set.
    case contiguous_blocks(sorted_blocks) do
      :ok ->
        assemble_blocks(sorted_blocks)

      {:error, missing_block} ->
        emit_missing_block(missing_block, sorted_blocks)
        nil
    end
  end

  def reset_blocks(%__MODULE__{} = exchange) do
    %__MODULE__{exchange | blocks: %{}}
  end

  @spec set_last_reply(t(), binary(), binary() | nil) :: t()
  def set_last_reply(%__MODULE__{} = exchange, token, reply) do
    %__MODULE__{exchange | last_reply: {token, reply}}
  end

  def last_reply(%__MODULE__{last_reply: last_reply}) do
    last_reply
  end

  defp caller_for_token(%__MODULE__{callers: callers}, token) when is_binary(token) do
    Enum.find(callers, fn {caller_token, _from} -> caller_token == token end)
  end

  defp contiguous_blocks(sorted_blocks) do
    case Enum.reduce_while(sorted_blocks, {-1, true}, &contiguous_block_result/2) do
      {_last_block, true} -> :ok
      {missing_block, false} -> {:error, missing_block}
    end
  end

  defp contiguous_block_result({block_number, _payload}, {last_block, _valid?}) do
    if last_block + 1 == block_number do
      {:cont, {block_number, true}}
    else
      {:halt, {block_number - 1, false}}
    end
  end

  defp assemble_blocks(sorted_blocks) do
    payload = Enum.reduce(sorted_blocks, "", &append_block_payload/2)
    emit_assembled_blocks(length(sorted_blocks), payload, sorted_blocks)
    payload
  end

  defp append_block_payload({_block_number, payload}, acc) do
    acc <> payload
  end

  defp emit_missing_block(missing_block, sorted_blocks) do
    measurements = %{count: 1}
    metadata = %{missing_block: missing_block, received_blocks: length(sorted_blocks)}

    Telemetry.execute([:connection, :block, :missing], measurements, metadata)
  end

  defp emit_assembled_blocks(count, payload, sorted) do
    first = first_block(sorted)
    last = last_block(sorted)
    measurements = %{bytes: byte_size(payload), count: count}
    metadata = %{first_block: first, last_block: last}

    Telemetry.execute([:connection, :block, :assembled], measurements, metadata)
  end

  defp first_block([]) do
    nil
  end

  defp first_block([{first, _payload} | _sorted]) do
    first
  end

  defp last_block([]) do
    nil
  end

  defp last_block(sorted) do
    {last, _payload} = List.last(sorted)
    last
  end
end
