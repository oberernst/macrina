defmodule Macrina.Peer.Session do
  @moduledoc false

  # Per-peer connection GenServer. One process per unique remote {ip, port},
  # spawned by `Macrina.Endpoint` and supervised by `ConnectionSupervisor`.
  # Pure protocol state lives in `Macrina.Exchange`.

  use GenServer, restart: :transient

  alias Macrina.{
    Block1,
    Block1.Chunk,
    Blockwise,
    Codes,
    Endpoint,
    Exchange,
    Handler,
    Message,
    Message.Opts.Block,
    Observe,
    Observe.ClientSession,
    Observe.Subscription,
    Peer.State,
    Request,
    Response,
    Telemetry
  }

  import State, only: :functions

  @call_timeout :timer.seconds(10)
  @timeout :timer.minutes(5)
  @default_ack_timeout 2_000
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
      endpoint = Keyword.get(args, :endpoint)
      exchange_lifetime = Keyword.get(args, :exchange_lifetime, @default_exchange_lifetime)
      max_retransmit = Keyword.get(args, :max_retransmit, @default_max_retransmit)

      with {:ok, block1} <- build_block1_policy(args) do
        state =
          endpoint
          |> connection_state(
            handler,
            ip,
            port,
            socket,
            ack_timeout,
            block1,
            exchange_lifetime,
            max_retransmit
          )
          |> with_message_id_counter(args)

        GenServer.start_link(__MODULE__, state, name: name)
      end
    end
  end

  # Per-endpoint atomic counter (Wave C). When spawned by `Macrina.Endpoint`
  # we get the endpoint's shared counter; when spawned directly (tests, ad-hoc
  # client setups), fall back to a fresh per-session counter so the session
  # always has a stamping-source.
  defp with_message_id_counter(%State{} = state, args) do
    counter = Keyword.get(args, :message_id_counter) || :atomics.new(1, signed: false)
    %State{state | message_id_counter: counter}
  end

  # Overwrites a message's id with the next value from the per-endpoint
  # counter. Used for outbound messages this session originates (observe
  # block2 follow-ups, server-side observer notifications) — anywhere we
  # would otherwise inherit `Macrina.Message.build/2`'s random fallback.
  defp stamp_message_id(%State{message_id_counter: ref}, %Message{} = message) do
    %Message{message | id: Endpoint.next_message_id(ref)}
  end

  defp build_block1_policy(args) do
    Block1.new(
      max_body_size: Keyword.get(args, :block1_max_body_size, :infinity),
      mode: Keyword.get(args, :block1_mode, :atomic),
      preferred_block_size: Keyword.get(args, :block1_preferred_block_size)
    )
  end

  def call(pid, message, timeout \\ @call_timeout) do
    GenServer.call(pid, {:request, message}, timeout)
  end

  def observe_subscribe(pid, %Subscription{} = subscription, observe_value) do
    GenServer.call(pid, {:observe_subscribe, subscription, observe_value})
  end

  def observe_unsubscribe(pid, token) when is_binary(token) do
    GenServer.call(pid, {:observe_unsubscribe, token})
  end

  def notify_observer(pid, notification, %Response{} = response) do
    GenServer.cast(pid, {:observe_notify, notification, response})
  end

  def init(state) do
    execute_connection_event(state, [:start], %{system_time: System.system_time()}, %{})
    {:ok, state, @timeout}
  end

  def handle_call({:request, %Message{} = message}, from, %State{} = state) do
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

  def handle_call(
        {:observe_subscribe, %Subscription{} = subscription, observe_value},
        _from,
        %State{} = state
      ) do
    next_state = put_observe_subscription(state, subscription, observe_value)
    {:reply, :ok, next_state, @timeout}
  end

  def handle_call({:observe_unsubscribe, token}, _from, %State{} = state)
      when is_binary(token) do
    next_state = drop_observe_subscription(state, token)
    {:reply, :ok, next_state, @timeout}
  end

  def handle_cast({:observe_notify, notification, %Response{} = response}, %State{} = state) do
    next_state = send_observe_notification(state, notification, response)
    {:noreply, next_state, @timeout}
  end

  def handle_info({:coap, packet}, %State{} = state) do
    decoded = Message.decode(packet)
    next_state = next_packet_state(decoded, state)

    {:noreply, next_state, @timeout}
  end

  def handle_info({:retransmit, token}, %State{} = state) do
    {_timer_ref, state_without_timer} = pop_retry_timer(state, token)
    {action, next_state} = retry_request(state_without_timer, token)

    final_state = handle_retry_action(action, next_state)

    {:noreply, final_state, @timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def terminate(:normal, state) do
    Observe.drop_connection(self())
    execute_connection_event(state, [:stop], %{system_time: System.system_time()}, %{})
  end

  defp reply_to_client(%State{} = state, message) do
    {caller, next_state} = pop_caller_for_token(state, message.token)

    unless is_nil(caller) do
      {_, from} = caller
      GenServer.reply(from, {:ok, message})
    end

    next_state
  end

  defp handle(%State{} = state, message) do
    case Handler.call(state.handler, state, message) do
      nil ->
        execute_connection_event(state, [:reply, :skipped], %{count: 1}, %{stage: :handler})
        cache_reply(state, message, nil)

      reply ->
        {next_state, prepared_reply} = prepare_observe_reply(state, message, reply)

        case encoded_reply(prepared_reply) do
          {:ok, bin} ->
            send_reply(next_state, bin, %{
              code: prepared_reply.code,
              stage: :handler,
              type: prepared_reply.type
            })

            cache_reply(next_state, message, bin)

          {:error, reason} ->
            emit_reply_error(next_state, :encode, :handler, reason)
            next_state
        end
    end
  end

  defp handle(%State{} = state, message, :continue) do
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

  defp completed_block_state(state, message, nil) do
    emit_incomplete_transfer(state, message)
    reply_incomplete_transfer(state, message)
  end

  defp completed_block_state(state, message, payload) do
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
        handle_observe_response(state, message)
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
    Keyword.get(args, :name, {:global, {__MODULE__, Macrina.Peer.label(ip, port)}})
  end

  defp connection_state(
         endpoint,
         handler,
         ip,
         port,
         socket,
         ack_timeout,
         %Block1{} = block1,
         exchange_lifetime,
         max_retransmit
       ) do
    %State{
      ack_timeout: ack_timeout,
      block1: block1,
      endpoint: endpoint,
      exchange: %Exchange{},
      exchange_lifetime: exchange_lifetime,
      handler: handler,
      ip: ip,
      max_retransmit: max_retransmit,
      observe_subscriptions: %{},
      port: port,
      retry_timers: %{},
      socket: socket
    }
  end

  defp maybe_track_request(%State{} = state, %Message{type: :con} = message, from, packet) do
    state
    |> track_request(message, from, packet)
    |> schedule_retry_timer(message.token, 0)
  end

  defp maybe_track_request(%State{} = state, _message, _from, _packet) do
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
         %State{ack_timeout: ack_timeout} = state,
         token,
         retransmissions_sent
       ) do
    delay = ack_timeout * trunc(:math.pow(2, retransmissions_sent))
    schedule_request_timer(state, token, delay)
  end

  defp schedule_response_timeout(%State{exchange_lifetime: exchange_lifetime} = state, token) do
    schedule_request_timer(state, token, exchange_lifetime)
  end

  defp schedule_request_timer(%State{} = state, token, delay) do
    timer_ref = Process.send_after(self(), {:retransmit, token}, delay)

    put_retry_timer(state, token, timer_ref)
  end

  defp cancel_retry_timer(%State{} = state, token) do
    case pop_retry_timer(state, token) do
      {nil, next_state} ->
        next_state

      {timer_ref, next_state} ->
        Process.cancel_timer(timer_ref)
        next_state
    end
  end

  defp complete_pending_request_state(%State{} = state, token) do
    {_request, next_state} = complete_pending_request(state, token)
    next_state
  end

  defp maybe_acknowledge_response(%State{} = state, %Message{type: :con, id: id}) do
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

  defp maybe_acknowledge_response(%State{} = state, _message) do
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

  defp maybe_continue_block1_transfer(
         %State{block1: %Block1{mode: :streaming}} = state,
         message
       ) do
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

  defp maybe_complete_block1_transfer(
         %State{block1: %Block1{mode: :streaming}} = state,
         message
       ) do
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

  defp block1_transfer_too_large?(
         %State{block1: %Block1{max_body_size: :infinity}},
         _message
       ) do
    false
  end

  defp block1_transfer_too_large?(
         %State{block1: %Block1{max_body_size: limit}} = state,
         message
       )
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
         %State{block1: %Block1{preferred_block_size: preferred_block_size}},
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
    State.reply(state, bin)

    measurements = %{bytes: byte_size(bin)}
    execute_connection_event(state, [:reply, :sent], measurements, metadata)
  end

  defp execute_connection_event(state, parts, measurements, metadata) do
    event_metadata = Map.merge(connection_metadata(state), metadata)
    Telemetry.execute([:connection | parts], measurements, event_metadata)
  end

  defp connection_metadata(state) do
    peer_name = Macrina.Peer.label(state.ip, state.port)

    %{ip: state.ip, peer: peer_name, port: state.port}
  end

  defp prepare_observe_reply(%State{endpoint: nil} = state, _request, %Message{} = reply) do
    {state, reply}
  end

  defp prepare_observe_reply(%State{} = state, %Message{} = request, %Message{} = reply) do
    case observe_request_action(request) do
      {:register, path} when reply.code == :content ->
        case Observe.register(state.endpoint, self(), path, request.token) do
          {:ok, observe_value} ->
            next_reply = put_message_option(reply, "Observe", observe_value)
            {state, next_reply}

          {:error, _reason} ->
            {state, reply}
        end

      {:cancel, _path} ->
        :ok = Observe.cancel(state.endpoint, self(), request.token)
        {state, delete_message_option(reply, "Observe")}

      :ignore ->
        {state, reply}
    end
  end

  defp observe_request_action(%Message{} = message) do
    with {:ok, request} <- Request.from_message(message),
         :get <- request.method do
      case Request.observe(request) do
        0 -> {:register, request.path}
        1 -> {:cancel, request.path}
        _other -> :ignore
      end
    else
      _other -> :ignore
    end
  end

  defp handle_observe_response(%State{} = state, %Message{} = message) do
    case ClientSession.fetch(state.observe_subscriptions, message.token) do
      {:ok, subscription_entry} ->
        next_state =
          state
          |> maybe_acknowledge_response(message)
          |> handle_client_observe_response(subscription_entry, message)

        {:handled, next_state}

      :error ->
        :miss
    end
  end

  defp handle_client_observe_response(
         %State{} = state,
         subscription_entry,
         %Message{} = message
       ) do
    observe_value = message_option(message.options, "Observe")

    if ClientSession.stale?(subscription_entry, observe_value) do
      state
    else
      next_observe = observe_value || subscription_entry.last_observe
      subscription_entry = %{subscription_entry | last_observe: next_observe}
      next_state = put_observe_entry(state, subscription_entry)
      maybe_collect_observe_block2(next_state, subscription_entry, message)
    end
  end

  defp maybe_collect_observe_block2(
         %State{} = state,
         subscription_entry,
         %Message{descriptive_block: nil} = message
       ) do
    state
    |> clear_observe_transfers(subscription_entry.subscription.token)
    |> deliver_observe_response(subscription_entry.subscription, message)
  end

  defp maybe_collect_observe_block2(
         %State{} = state,
         %{subscription: %Subscription{request: request}} = subscription_entry,
         %Message{descriptive_block: %Block{more: more}} = message
       ) do
    if is_nil(Request.block2(request)) do
      transfers = subscription_entry.transfers

      with {:ok, next_transfers} <- Blockwise.put_transfer(transfers, message) do
        next_state =
          put_observe_transfers(state, subscription_entry.subscription.token, next_transfers)

        if more do
          send_next_observe_block_request(next_state, subscription_entry.subscription, message)
        else
          finalize_observe_block2(
            next_state,
            subscription_entry.subscription,
            message,
            next_transfers
          )
        end
      else
        {:error, _reason} ->
          deliver_observe_response(state, subscription_entry.subscription, message)
      end
    else
      deliver_observe_response(state, subscription_entry.subscription, message)
    end
  end

  defp finalize_observe_block2(
         %State{} = state,
         %Subscription{} = subscription,
         message,
         transfers
       ) do
    case Blockwise.assemble(transfers, message) do
      {:ok, payload, _metadata} ->
        full_message = %{message | payload: payload}

        state
        |> clear_observe_transfers(subscription.token)
        |> deliver_observe_response(subscription, full_message)

      _other ->
        deliver_observe_response(state, subscription, message)
    end
  end

  defp send_next_observe_block_request(
         %State{} = state,
         %Subscription{} = subscription,
         message
       ) do
    block = message.descriptive_block
    next_block = %Block{number: block.number + 1, more: false, size: block.size}

    request =
      subscription.request
      |> clear_request_option("Observe")
      |> Request.put_block2(next_block)

    request = %Request{request | id: nil, token: subscription.token}

    with {:ok, next_message} <- Request.to_message(request),
         next_message = stamp_message_id(state, next_message),
         {:ok, packet} <- Message.encode(next_message) do
      :gen_udp.send(state.socket, {state.ip, state.port}, packet)
      state
    else
      _other -> state
    end
  end

  defp deliver_observe_response(
         %State{} = state,
         %Subscription{} = subscription,
         %Message{} = message
       ) do
    response = Response.from_message(message)
    send(subscription.notify_to, {:macrina_observe, subscription, response})
    state
  end

  defp send_observe_notification(%State{} = state, notification, %Response{} = response) do
    notification_response =
      response
      |> normalize_notification_type()
      |> Response.put_observe(notification.observe)

    notification_response = %Response{
      notification_response
      | id: nil,
        token: notification.token
    }

    with {:ok, message} <- Response.to_message(notification_response, nil),
         message = stamp_message_id(state, message),
         {:ok, packet} <- Message.encode(message) do
      send_reply(state, packet, %{
        code: message.code,
        observe: notification.observe,
        path: notification.path,
        stage: :observe,
        type: message.type
      })

      Telemetry.execute(
        [:observe, :notify],
        %{bytes: byte_size(packet), count: 1},
        %{path: notification.path, token: notification.token, observe: notification.observe}
      )

      state
    else
      {:error, reason} ->
        execute_connection_event(state, [:reply, :build, :error], %{count: 1}, %{
          error: reason,
          stage: :observe
        })

        state
    end
  end

  defp put_observe_subscription(
         %State{observe_subscriptions: session} = state,
         %Subscription{} = subscription,
         observe_value
       ) do
    %State{
      state
      | observe_subscriptions: ClientSession.put(session, subscription, observe_value)
    }
  end

  defp put_observe_entry(%State{observe_subscriptions: session} = state, entry) do
    %State{state | observe_subscriptions: Map.put(session, entry.token, entry)}
  end

  defp drop_observe_subscription(%State{observe_subscriptions: session} = state, token) do
    %State{state | observe_subscriptions: ClientSession.drop(session, token)}
  end

  defp put_observe_transfers(
         %State{observe_subscriptions: session} = state,
         token,
         transfers
       ) do
    %State{
      state
      | observe_subscriptions: ClientSession.put_transfers(session, token, transfers)
    }
  end

  defp clear_observe_transfers(%State{observe_subscriptions: session} = state, token) do
    %State{state | observe_subscriptions: ClientSession.clear_transfers(session, token)}
  end

  defp normalize_notification_type(%Response{type: type} = response) when type in [:con, :non] do
    response
  end

  defp normalize_notification_type(%Response{} = response) do
    %Response{response | type: :non}
  end

  defp clear_request_option(%Request{options: options} = request, name) do
    next_options = Enum.reject(options, fn {option_name, _value} -> option_name == name end)
    %Request{request | options: next_options}
  end

  defp put_message_option(%Message{options: options} = message, name, value) do
    next_options = delete_option(options, name) ++ [{name, value}]
    %Message{message | options: next_options}
  end

  defp delete_message_option(%Message{options: options} = message, name) do
    %Message{message | options: delete_option(options, name)}
  end

  defp delete_option(options, name) do
    Enum.reject(options, fn {option_name, _value} -> option_name == name end)
  end

  defp message_option(options, name) do
    case List.keyfind(options, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp fetch_opt(args, key) do
    case Keyword.fetch(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
