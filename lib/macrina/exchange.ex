defmodule Macrina.Exchange do
  @moduledoc """
  Pure protocol state for a single peer exchange lifecycle.

  `Macrina.Connection.Server` owns socket orchestration; this module owns the
  token, message-id, caller, cached-reply, and blockwise tracking that sits
  behind that shell.
  """

  alias Macrina.{Message, Message.Opts.Block, Telemetry}

  @type reply_entry :: %{reply: binary() | nil, stored_at: integer()}

  defstruct blocks: %{}, callers: [], ids: [], replies: %{}, requests: %{}, tokens: []

  @type pending_request :: %{
          attempts: non_neg_integer(),
          from: tuple(),
          id: non_neg_integer(),
          packet: binary() | nil,
          retries: non_neg_integer(),
          state: :awaiting_ack | :awaiting_response,
          token: binary()
        }

  @type t :: %__MODULE__{
          blocks: %{optional(non_neg_integer()) => binary()},
          callers: [{binary(), tuple()}],
          ids: [non_neg_integer()],
          replies: %{optional(non_neg_integer()) => reply_entry()},
          requests: %{optional(binary()) => pending_request()},
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

  @spec track_request(t(), Message.t(), tuple(), binary(), non_neg_integer()) :: t()
  def track_request(
        %__MODULE__{requests: requests} = exchange,
        %Message{} = message,
        from,
        packet,
        retries
      )
      when is_binary(packet) and is_integer(retries) and retries >= 0 do
    request = %{
      attempts: 0,
      from: from,
      id: message.id,
      packet: packet,
      retries: retries,
      state: :awaiting_ack,
      token: message.token
    }

    %__MODULE__{exchange | requests: Map.put(requests, message.token, request)}
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

  @spec cache_reply(t(), Message.t(), binary() | nil) :: t()
  def cache_reply(%__MODULE__{} = exchange, %Message{} = message, reply)
      when is_binary(reply) or is_nil(reply) do
    now = System.monotonic_time(:millisecond)
    cache_reply(exchange, message, reply, now)
  end

  @spec cache_reply(t(), Message.t(), binary() | nil, integer()) :: t()
  def cache_reply(%__MODULE__{replies: replies} = exchange, %Message{id: id}, reply, now)
      when is_binary(reply) or is_nil(reply) do
    reply_entry = %{reply: reply, stored_at: now}
    next_replies = Map.put(replies, id, reply_entry)

    %__MODULE__{exchange | replies: next_replies}
  end

  @spec cached_reply(t(), Message.t()) :: {:ok, binary() | nil} | :error
  def cached_reply(%__MODULE__{} = exchange, %Message{} = message) do
    cached_reply(exchange, message, System.monotonic_time(:millisecond), :infinity)
  end

  @spec cached_reply(t(), Message.t(), integer(), integer() | :infinity) ::
          {:ok, binary() | nil} | :error
  def cached_reply(%__MODULE__{replies: replies}, %Message{id: id}, now, lifetime)
      when is_integer(now) do
    case Map.fetch(replies, id) do
      {:ok, %{reply: reply, stored_at: stored_at}} ->
        if reply_expired?(stored_at, now, lifetime) do
          :error
        else
          {:ok, reply}
        end

      :error ->
        :error
    end
  end

  @spec pending_request(t(), binary()) :: {:ok, pending_request()} | :error
  def pending_request(%__MODULE__{requests: requests}, token) when is_binary(token) do
    Map.fetch(requests, token)
  end

  @spec pending_request_for_id(t(), non_neg_integer()) ::
          {:ok, {binary(), pending_request()}} | :error
  def pending_request_for_id(%__MODULE__{requests: requests}, id) when is_integer(id) do
    Enum.find_value(requests, :error, fn {token, request} ->
      if request.id == id do
        {:ok, {token, request}}
      end
    end)
  end

  @spec acknowledge_request(t(), Message.t()) :: {pending_request() | nil, t()}
  def acknowledge_request(%__MODULE__{} = exchange, %Message{id: id}) do
    case pending_request_for_id(exchange, id) do
      {:ok, {token, request}} ->
        next_request = %{request | packet: nil, state: :awaiting_response}
        next_exchange = put_request(exchange, token, next_request)

        {request, next_exchange}

      :error ->
        {nil, exchange}
    end
  end

  @spec retry_request(t(), binary()) ::
          {{:retransmit, pending_request()} | {:timeout, pending_request()} | :ignore, t()}
  def retry_request(%__MODULE__{} = exchange, token) when is_binary(token) do
    case pending_request(exchange, token) do
      {:ok, %{attempts: attempts, retries: retries, state: :awaiting_ack} = request}
      when attempts < retries ->
        next_request = %{request | attempts: attempts + 1}
        next_exchange = put_request(exchange, token, next_request)

        {{:retransmit, next_request}, next_exchange}

      {:ok, %{state: :awaiting_ack} = request} ->
        {_request, next_exchange} = complete_pending_request(exchange, token)
        {{:timeout, request}, next_exchange}

      {:ok, %{state: :awaiting_response} = request} ->
        {_request, next_exchange} = complete_pending_request(exchange, token)
        {{:timeout, request}, next_exchange}

      _other ->
        {:ignore, exchange}
    end
  end

  @spec complete_pending_request(t(), binary()) :: {pending_request() | nil, t()}
  def complete_pending_request(%__MODULE__{requests: requests} = exchange, token)
      when is_binary(token) do
    case Map.pop(requests, token) do
      {nil, _next_requests} ->
        {nil, exchange}

      {request, next_requests} ->
        next_exchange =
          exchange
          |> pop_caller({token, request.from})
          |> delete_id(request.id)
          |> delete_token(token)

        {%{request | token: token}, %__MODULE__{next_exchange | requests: next_requests}}
    end
  end

  defp caller_for_token(%__MODULE__{callers: callers}, token) when is_binary(token) do
    Enum.find(callers, fn {caller_token, _from} -> caller_token == token end)
  end

  defp delete_id(%__MODULE__{ids: ids} = exchange, id) do
    %__MODULE__{exchange | ids: List.delete(ids, id)}
  end

  defp delete_token(%__MODULE__{tokens: tokens} = exchange, token) do
    %__MODULE__{exchange | tokens: List.delete(tokens, token)}
  end

  defp put_request(%__MODULE__{requests: requests} = exchange, token, request) do
    %__MODULE__{exchange | requests: Map.put(requests, token, request)}
  end

  defp reply_expired?(_stored_at, _now, :infinity) do
    false
  end

  defp reply_expired?(stored_at, now, lifetime) when is_integer(lifetime) and lifetime >= 0 do
    now - stored_at >= lifetime
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
