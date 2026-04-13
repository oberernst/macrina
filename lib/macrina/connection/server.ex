defmodule Macrina.Connection.Server do
  use GenServer, restart: :transient

  alias Macrina.{
    Block1.Chunk,
    Codes,
    Connection,
    Exchange,
    Handler,
    Message,
    Message.Opts.Block,
    Telemetry
  }

  import Connection, only: :functions

  @call_timeout :timer.seconds(10)
  @timeout :timer.minutes(5)
  @default_ack_timeout 2_000
  @default_block1_max_body_size :infinity
  @default_exchange_lifetime 247_000
  @default_max_retransmit 4
  @request_codes Codes.method_codes()
  @response_codes Codes.response_codes()

  def start_link(args) do
    with {:ok, handler} <- fetch_opt(args, :handler),
         {:ok, ip} <- fetch_opt(args, :ip),
         {:ok, port} <- fetch_opt(args, :port),
         {:ok, socket} <- fetch_opt(args, :socket) do
      name = connection_name(args, ip, port)
      ack_timeout = Keyword.get(args, :ack_timeout, @default_ack_timeout)

      block1_max_body_size =
        Keyword.get(args, :block1_max_body_size, @default_block1_max_body_size)

      block1_mode = Keyword.get(args, :block1_mode, :atomic)
      block1_preferred_block_size = Keyword.get(args, :block1_preferred_block_size)
      exchange_lifetime = Keyword.get(args, :exchange_lifetime, @default_exchange_lifetime)
      max_retransmit = Keyword.get(args, :max_retransmit, @default_max_retransmit)

      state =
        connection_state(
          handler,
          ip,
          port,
          socket,
          ack_timeout,
          block1_max_body_size,
          block1_mode,
          block1_preferred_block_size,
          exchange_lifetime,
          max_retransmit
        )

      GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def call(pid, message, timeout \\ @call_timeout) do
    GenServer.call(pid, {:request, message}, timeout)
  end

  def init(state) do
    execute_connection_event(state, [:start], %{system_time: System.system_time()}, %{})
    {:ok, state, @timeout}
  end

  def handle_call({:request, %Message{} = message}, from, %Connection{} = state) do
    case Message.encode(message) do
      {:ok, packet} ->
        :gen_udp.send(state.socket, {state.ip, state.port}, packet)

        next_state =
          state
          |> register_request(message, from)
          |> maybe_track_request(message, from, packet)

        {:noreply, next_state, @timeout}

      {:error, reason} ->
        execute_connection_event(state, [:request, :encode, :error], %{count: 1}, %{error: reason})

        error = {:encode_failed, reason}
        GenServer.reply(from, {:error, error})

        {:noreply, state, @timeout}
    end
  end

  def handle_info({:coap, packet}, %Connection{} = state) do
    decoded = Message.decode(packet)
    next_state = next_packet_state(decoded, state)

    {:noreply, next_state, @timeout}
  end

  def handle_info({:retransmit, token}, %Connection{} = state) do
    {_timer_ref, state_without_timer} = pop_retry_timer(state, token)
    {action, next_state} = retry_request(state_without_timer, token)

    final_state = handle_retry_action(action, next_state)

    {:noreply, final_state, @timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def terminate(:normal, state) do
    execute_connection_event(state, [:stop], %{system_time: System.system_time()}, %{})
  end

  defp reply_to_client(%Connection{} = state, message) do
    {caller, next_state} = pop_caller_for_token(state, message.token)

    unless is_nil(caller) do
      {_, from} = caller
      GenServer.reply(from, {:ok, message})
    end

    next_state
  end

  defp handle(%Connection{} = state, message) do
    case Handler.call(state.handler, state, message) do
      nil ->
        execute_connection_event(state, [:reply, :skipped], %{count: 1}, %{stage: :handler})
        cache_reply(state, message, nil)

      reply ->
        case encoded_reply(reply) do
          {:ok, bin} ->
            send_reply(state, bin, %{code: reply.code, stage: :handler, type: reply.type})
            cache_reply(state, message, bin)

          {:error, reason} ->
            emit_reply_error(state, :encode, :handler, reason)
            state
        end
    end
  end

  defp handle(%Connection{} = state, message, :continue) do
    reply_opts = [code: :continue, options: block1_response_options(state, message), type: :ack]

    case send_built_reply(state, message, reply_opts, %{stage: :continue}) do
      {:ok, _reply, encoded_reply} ->
        cache_reply(state, message, encoded_reply)

      {:error, step, reason} ->
        emit_reply_error(state, step, :continue, reason)
        state
    end
  end

  defp next_packet_state({:ok, %Message{} = message}, state) do
    case handle_exchange_message(state, message) do
      {:handled, next_state} ->
        next_state

      :miss ->
        case duplicate_request_reply(state, message) do
          {:duplicate, reply} ->
            resend_cached_reply(state, reply, message)

          :miss ->
            handle_packet_message(message, state)
        end
    end
  end

  defp next_packet_state(_decoded, state) do
    execute_connection_event(state, [:decode, :error], %{count: 1}, %{})
    state
  end

  defp handle_packet_message(%Message{descriptive_block: %Block{more: true}} = message, state) do
    case store_block(state, message) do
      {:ok, next_state} ->
        maybe_continue_block1_transfer(next_state, message)

      {:error, _reason} ->
        reply_incomplete_transfer(state, message)
    end
  end

  defp handle_packet_message(%Message{descriptive_block: %Block{more: false}} = message, state) do
    case store_block(state, message) do
      {:ok, block_state} ->
        maybe_complete_block1_transfer(block_state, message)

      {:error, _reason} ->
        reply_incomplete_transfer(state, message)
    end
  end

  defp handle_packet_message(%Message{type: type} = message, state) when type in [:ack, :rst] do
    state
    |> handle(message)
    |> reply_to_client(message)
    |> complete_request(message)
  end

  defp handle_packet_message(%Message{} = message, state) do
    state
    |> handle(message)
    |> reply_to_client(message)
  end

  defp completed_block_state(state, message, payload) do
    cond do
      is_nil(payload) ->
        emit_incomplete_transfer(state, message)
        reply_incomplete_transfer(state, message)

      true ->
        full_message = %Message{message | payload: payload}

        execute_connection_event(
          state,
          [:block, :completed],
          %{bytes: byte_size(payload), count: 1},
          %{code: full_message.code, type: full_message.type}
        )

        state
        |> handle(full_message)
        |> reset_blocks(message)
        |> reply_to_client(full_message)
    end
  end

  defp reply_incomplete_transfer(state, message) do
    reply_opts = [
      code: :request_entity_incomplete,
      options: block1_response_options(state, message),
      type: :ack
    ]

    case send_built_reply(
           state,
           message,
           reply_opts,
           %{stage: :incomplete_transfer}
         ) do
      {:ok, _reply, encoded_reply} ->
        state
        |> cache_reply(message, encoded_reply)
        |> reset_blocks(message)
        |> reply_to_client(message)

      {:error, step, reason} ->
        emit_reply_error(state, step, :incomplete_transfer, reason)

        state
        |> reset_blocks(message)
        |> reply_to_client(message)
    end
  end

  defp resend_cached_reply(state, reply, message) do
    if reply do
      send_reply(state, reply, %{cached: true, stage: :resend})
    end

    reply_to_client(state, message)
  end

  defp handle_exchange_message(state, %Message{type: :ack, code: :empty} = message) do
    case acknowledge_request(state, message) do
      {nil, _next_state} ->
        :miss

      {%{token: token}, next_state} ->
        acknowledged_state =
          next_state
          |> cancel_retry_timer(token)
          |> schedule_response_timeout(token)

        {:handled, acknowledged_state}
    end
  end

  defp handle_exchange_message(state, %Message{type: :rst} = message) do
    case pending_request_for_id(state, message.id) do
      {:ok, {token, request}} ->
        next_state =
          state
          |> cancel_retry_timer(token)
          |> complete_pending_request_state(token)

        GenServer.reply(request.from, {:error, :request_reset})

        {:handled, next_state}

      :error ->
        :miss
    end
  end

  defp handle_exchange_message(state, %Message{code: code} = message)
       when code in @response_codes do
    case pending_request(state, message.token) do
      {:ok, request} ->
        next_state =
          state
          |> cancel_retry_timer(message.token)
          |> maybe_acknowledge_response(message)
          |> complete_pending_request_state(message.token)

        GenServer.reply(request.from, {:ok, message})

        {:handled, next_state}

      :error ->
        :miss
    end
  end

  defp handle_exchange_message(_state, _message) do
    :miss
  end

  defp duplicate_request_reply(state, message) do
    if duplicate_request_message?(message) do
      case cached_reply(state, message) do
        {:ok, reply} ->
          emit_dedup_hit(state, message, reply)
          {:duplicate, reply}

        :error ->
          :miss
      end
    else
      :miss
    end
  end

  defp duplicate_request_message?(%Message{code: code, type: :con}) do
    code in @request_codes
  end

  defp duplicate_request_message?(_message) do
    false
  end

  defp connection_name(args, ip, port) do
    Keyword.get(args, :name, {:global, {__MODULE__, Macrina.conn_name(ip, port)}})
  end

  defp connection_state(
         handler,
         ip,
         port,
         socket,
         ack_timeout,
         block1_max_body_size,
         block1_mode,
         block1_preferred_block_size,
         exchange_lifetime,
         max_retransmit
       ) do
    %Connection{
      ack_timeout: ack_timeout,
      block1_max_body_size: block1_max_body_size,
      block1_mode: block1_mode,
      block1_preferred_block_size: block1_preferred_block_size,
      exchange: %Exchange{},
      exchange_lifetime: exchange_lifetime,
      handler: handler,
      ip: ip,
      max_retransmit: max_retransmit,
      port: port,
      retry_timers: %{},
      socket: socket
    }
  end

  defp maybe_track_request(%Connection{} = state, %Message{type: :con} = message, from, packet) do
    state
    |> track_request(message, from, packet)
    |> schedule_retry_timer(message.token, 0)
  end

  defp maybe_track_request(%Connection{} = state, _message, _from, _packet) do
    state
  end

  defp handle_retry_action({:retransmit, request}, state) do
    :gen_udp.send(state.socket, {state.ip, state.port}, request.packet)

    emit_retransmit(state, request)
    schedule_retry_timer(state, request.token, request.attempts)
  end

  defp handle_retry_action({:timeout, request}, state) do
    emit_timeout(state, request)
    GenServer.reply(request.from, {:error, timeout_reason(request.state)})
    state
  end

  defp handle_retry_action(:ignore, state) do
    state
  end

  defp schedule_retry_timer(
         %Connection{ack_timeout: ack_timeout} = state,
         token,
         retransmissions_sent
       ) do
    delay = ack_timeout * trunc(:math.pow(2, retransmissions_sent))
    schedule_request_timer(state, token, delay)
  end

  defp schedule_response_timeout(%Connection{exchange_lifetime: exchange_lifetime} = state, token) do
    schedule_request_timer(state, token, exchange_lifetime)
  end

  defp schedule_request_timer(%Connection{} = state, token, delay) do
    timer_ref = Process.send_after(self(), {:retransmit, token}, delay)

    put_retry_timer(state, token, timer_ref)
  end

  defp cancel_retry_timer(%Connection{} = state, token) do
    case pop_retry_timer(state, token) do
      {nil, next_state} ->
        next_state

      {timer_ref, next_state} ->
        Process.cancel_timer(timer_ref)
        next_state
    end
  end

  defp complete_pending_request_state(%Connection{} = state, token) do
    {_request, next_state} = complete_pending_request(state, token)
    next_state
  end

  defp maybe_acknowledge_response(%Connection{} = state, %Message{type: :con, id: id}) do
    case Message.build(:empty, id: id, type: :ack) do
      {:ok, ack} ->
        case encoded_reply(ack) do
          {:ok, encoded_ack} ->
            send_reply(state, encoded_ack, %{
              code: :empty,
              stage: :separate_response_ack,
              type: :ack
            })

            state

          {:error, reason} ->
            emit_reply_error(state, :encode, :separate_response_ack, reason)
            state
        end

      {:error, reason} ->
        emit_reply_error(state, :build, :separate_response_ack, reason)
        state
    end
  end

  defp maybe_acknowledge_response(%Connection{} = state, _message) do
    state
  end

  defp emit_block_continue(state, message) do
    measurements = %{
      block_number: message.descriptive_block.number,
      block_size: message.descriptive_block.size,
      count: 1
    }

    metadata = %{code: message.code, more: true, type: message.type}

    execute_connection_event(state, [:block, :continue], measurements, metadata)
  end

  defp emit_dedup_hit(state, message, reply) do
    measurements = %{count: 1}

    metadata = %{
      cached: not is_nil(reply),
      code: message.code,
      id: message.id,
      type: message.type
    }

    event_metadata = Map.merge(connection_metadata(state), metadata)
    Telemetry.execute([:exchange, :dedup, :hit], measurements, event_metadata)
  end

  defp emit_retransmit(state, request) do
    measurements = %{attempt: request.attempts, bytes: byte_size(request.packet), count: 1}
    metadata = %{id: request.id, token: request.token}

    event_metadata = Map.merge(connection_metadata(state), metadata)
    Telemetry.execute([:exchange, :retransmit], measurements, event_metadata)
  end

  defp emit_timeout(state, request) do
    measurements = %{count: 1, retransmissions: request.attempts}
    metadata = %{id: request.id, phase: request.state, token: request.token}

    event_metadata = Map.merge(connection_metadata(state), metadata)
    Telemetry.execute([:exchange, :timeout], measurements, event_metadata)
  end

  defp timeout_reason(:awaiting_ack) do
    :ack_timeout
  end

  defp timeout_reason(:awaiting_response) do
    :response_timeout
  end

  defp emit_incomplete_transfer(state, message) do
    measurements = %{count: 1}
    metadata = %{code: message.code, type: message.type}

    execute_connection_event(state, [:block, :incomplete], measurements, metadata)
  end

  defp emit_reply_error(state, step, stage, reason) do
    execute_connection_event(state, [:reply, step, :error], %{count: 1}, %{
      error: reason,
      stage: stage
    })
  end

  defp maybe_continue_block1_transfer(%Connection{block1_mode: :streaming} = state, message) do
    if block1_transfer_too_large?(state, message) do
      reply_too_large_transfer(state, message)
    else
      stream_block1_chunk(state, message)
    end
  end

  defp maybe_continue_block1_transfer(state, message) do
    if block1_transfer_too_large?(state, message) do
      reply_too_large_transfer(state, message)
    else
      emit_block_continue(state, message)

      state
      |> handle(message, :continue)
      |> reply_to_client(message)
    end
  end

  defp maybe_complete_block1_transfer(%Connection{block1_mode: :streaming} = state, message) do
    if block1_transfer_too_large?(state, message) do
      reply_too_large_transfer(state, message)
    else
      stream_block1_chunk(state, message)
    end
  end

  defp maybe_complete_block1_transfer(state, message) do
    if block1_transfer_too_large?(state, message) do
      reply_too_large_transfer(state, message)
    else
      payload = read_blocks(state, message)
      completed_block_state(state, message, payload)
    end
  end

  defp block1_transfer_too_large?(%Connection{block1_max_body_size: :infinity}, _message) do
    false
  end

  defp block1_transfer_too_large?(%Connection{block1_max_body_size: limit} = state, message)
       when is_integer(limit) and limit >= 0 do
    case block_transfer(state, message) do
      {:ok, %{bytes: bytes}} -> bytes > limit
      :error -> false
    end
  end

  defp reply_too_large_transfer(state, message) do
    reply_opts = [
      code: :request_entity_too_large,
      options: block1_response_options(state, message),
      type: :ack
    ]

    case send_built_reply(state, message, reply_opts, %{stage: :too_large_transfer}) do
      {:ok, _reply, encoded_reply} ->
        state
        |> cache_reply(message, encoded_reply)
        |> reset_blocks(message)
        |> reply_to_client(message)

      {:error, step, reason} ->
        emit_reply_error(state, step, :too_large_transfer, reason)

        state
        |> reset_blocks(message)
        |> reply_to_client(message)
    end
  end

  defp stream_block1_chunk(state, message) do
    case block1_chunk(state, message) do
      {:ok, chunk} ->
        stream_handler_result(state, message, chunk, Handler.call(state.handler, state, chunk))

      :error ->
        reply_incomplete_transfer(state, message)
    end
  end

  defp block1_chunk(state, message) do
    case block_transfer(state, message) do
      {:ok, transfer} -> {:ok, Chunk.from_message(message, transfer)}
      :error -> :error
    end
  end

  defp stream_handler_result(state, message, %Chunk{complete: false}, nil) do
    emit_block_continue(state, message)

    state
    |> handle(message, :continue)
    |> reply_to_client(message)
  end

  defp stream_handler_result(state, message, %Chunk{complete: true}, nil) do
    state
    |> reset_blocks(message)
    |> reply_to_client(message)
  end

  defp stream_handler_result(state, message, _chunk, %Message{} = reply) do
    case encoded_reply(reply) do
      {:ok, bin} ->
        send_reply(state, bin, %{code: reply.code, stage: :handler, type: reply.type})

        next_state =
          state
          |> cache_reply(message, bin)
          |> reset_blocks(message)

        reply_to_client(next_state, reply)

      {:error, reason} ->
        emit_reply_error(state, :encode, :handler, reason)

        state
        |> reset_blocks(message)
        |> reply_to_client(message)
    end
  end

  defp block1_response_options(state, %Message{descriptive_block: %Block{} = block}) do
    response_block = %Block{
      number: block.number,
      more: false,
      size: block1_response_block_size(state, block)
    }

    [{"Block1", response_block}]
  end

  defp block1_response_options(_state, _message) do
    []
  end

  defp block1_response_block_size(
         %Connection{block1_preferred_block_size: preferred_block_size},
         %Block{size: request_block_size}
       )
       when is_integer(preferred_block_size) and preferred_block_size > 0 do
    min(preferred_block_size, request_block_size)
  end

  defp block1_response_block_size(_state, %Block{size: request_block_size}) do
    request_block_size
  end

  defp send_built_reply(state, message, reply_opts, metadata) do
    with {:ok, reply} <- build_reply(message, reply_opts),
         {:ok, encoded_reply} <- encoded_reply(reply) do
      reply_metadata =
        metadata
        |> Map.put(:code, reply.code)
        |> Map.put(:type, reply.type)

      send_reply(state, encoded_reply, reply_metadata)

      {:ok, reply, encoded_reply}
    end
  end

  defp build_reply(message, reply_opts) do
    case Message.response(message, reply_opts) do
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, :build, reason}
    end
  end

  defp encoded_reply(reply) do
    case Message.encode(reply) do
      {:ok, encoded_reply} -> {:ok, encoded_reply}
      {:error, reason} -> {:error, :encode, reason}
    end
  end

  defp send_reply(state, bin, metadata) do
    Connection.reply(state, bin)

    measurements = %{bytes: byte_size(bin)}
    execute_connection_event(state, [:reply, :sent], measurements, metadata)
  end

  defp execute_connection_event(state, parts, measurements, metadata) do
    event_metadata = Map.merge(connection_metadata(state), metadata)
    Telemetry.execute([:connection | parts], measurements, event_metadata)
  end

  defp connection_metadata(state) do
    peer_name = Macrina.conn_name(state.ip, state.port)

    %{ip: state.ip, peer: peer_name, port: state.port}
  end

  defp fetch_opt(args, key) do
    case Keyword.fetch(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
