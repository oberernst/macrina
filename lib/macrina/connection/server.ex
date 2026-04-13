defmodule Macrina.Connection.Server do
  use GenServer, restart: :transient
  alias Macrina.{Connection, Handler, Message, Message.Opts.Block, Telemetry}
  import Connection, only: :functions

  @timeout :timer.minutes(5)

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    with {:ok, handler} <- fetch_opt(args, :handler),
         {:ok, ip} <- fetch_opt(args, :ip),
         {:ok, port} <- fetch_opt(args, :port),
         {:ok, socket} <- fetch_opt(args, :socket) do
      name = connection_name(args, ip, port)
      state = connection_state(handler, ip, port, socket)

      GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def call(pid, message, timeout \\ 2000) do
    GenServer.call(pid, {:request, message}, timeout)
  end

  # ------------------------------------------- Server ------------------------------------------- #

  def init(state) do
    execute_connection_event(state, [:start], %{system_time: System.system_time()}, %{})
    {:ok, state, @timeout}
  end

  def handle_call({:request, %Message{} = message}, from, %Connection{} = state) do
    case Message.encode(message) do
      {:ok, packet} ->
        next_state = request_state(state, message, from)

        :gen_udp.send(state.socket, {state.ip, state.port}, packet)

        {:noreply, next_state, @timeout}

      {:error, reason} ->
        execute_connection_event(state, [:request, :encode, :error], %{count: 1}, %{error: reason})

        error = {:encode_failed, reason}
        GenServer.reply(from, {:error, error})

        {:noreply, state, @timeout}
    end
  end

  def handle_info({:coap, packet}, %Connection{} = state) do
    {last_token, reply} = Connection.last_reply(state)
    decoded = Message.decode(packet)
    next_state = next_packet_state(decoded, state, last_token, reply)

    {:noreply, next_state, @timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def terminate(:normal, state) do
    execute_connection_event(state, [:stop], %{system_time: System.system_time()}, %{})
  end

  defp reply_to_client(%Connection{callers: callers} = state, message) do
    caller = Enum.find(callers, fn {t, _from} -> t == message.token end)

    unless is_nil(caller) do
      {_, from} = caller
      GenServer.reply(from, message)
    end

    pop_caller(state, caller)
  end

  defp handle(%Connection{} = state, message) do
    if reply = Handler.call(state.handler, state, message) do
      case Message.encode(reply) do
        {:ok, bin} ->
          send_reply(state, bin, %{code: reply.code, stage: :handler, type: reply.type})
          set_last_reply(state, message.token, bin)

        {:error, reason} ->
          execute_connection_event(state, [:reply, :encode, :error], %{count: 1}, %{
            error: reason,
            stage: :handler
          })

          set_last_reply(state, message.token, nil)
      end
    else
      execute_connection_event(state, [:reply, :skipped], %{count: 1}, %{stage: :handler})

      set_last_reply(state, message.token, nil)
    end
  end

  defp handle(%Connection{} = state, message, :continue) do
    case Message.response(message, code: :continue, type: :ack) do
      {:ok, continue_message} ->
        case Message.encode(continue_message) do
          {:ok, bin} ->
            send_reply(state, bin, %{
              code: continue_message.code,
              stage: :continue,
              type: continue_message.type
            })

            state

          {:error, reason} ->
            execute_connection_event(state, [:reply, :encode, :error], %{count: 1}, %{
              error: reason,
              stage: :continue
            })

            state
        end

      {:error, reason} ->
        execute_connection_event(state, [:reply, :build, :error], %{count: 1}, %{
          error: reason,
          stage: :continue
        })

        state
    end
  end

  defp next_packet_state(
         {:ok, %Message{descriptive_block: %Block{more: true}} = message},
         state,
         _last_token,
         _reply
       ) do
    log_continue(state, message)

    state
    |> push_block(message)
    |> handle(message, :continue)
    |> reply_to_client(message)
  end

  defp next_packet_state(
         {:ok, %Message{descriptive_block: %Block{more: false}} = message},
         state,
         last_token,
         reply
       ) do
    block_state = push_block(state, message)
    payload = read_blocks(block_state)

    completed_block_state(block_state, message, payload, last_token, reply)
  end

  defp next_packet_state({:ok, %Message{token: token} = message}, state, token, reply) do
    resend_cached_reply(state, reply, message)
  end

  defp next_packet_state({:ok, %Message{type: type} = message}, state, _last_token, _reply)
       when type in [:ack, :rst] do
    state
    |> handle(message)
    |> reply_to_client(message)
    |> pop_id(message)
    |> pop_token(message)
  end

  defp next_packet_state({:ok, %Message{} = message}, state, _last_token, _reply) do
    state
    |> handle(message)
    |> reply_to_client(message)
  end

  defp next_packet_state(_decoded, state, _last_token, _reply) do
    execute_connection_event(state, [:decode, :error], %{count: 1}, %{})
    state
  end

  defp completed_block_state(state, message, payload, last_token, reply) do
    cond do
      message.token == last_token ->
        log_resend_completed(state, message)
        resend_cached_reply(state, reply, message)

      is_nil(payload) ->
        log_incomplete_transfer(state, message)
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
        |> reset_blocks()
        |> reply_to_client(full_message)
    end
  end

  defp reply_incomplete_transfer(state, message) do
    case incomplete_transfer_reply(message) do
      {:ok, reply} ->
        case Message.encode(reply) do
          {:ok, encoded_reply} ->
            send_reply(state, encoded_reply, %{
              code: reply.code,
              stage: :incomplete_transfer,
              type: reply.type
            })

            state
            |> set_last_reply(message.token, encoded_reply)
            |> reset_blocks()
            |> reply_to_client(message)

          {:error, reason} ->
            execute_connection_event(
              state,
              [:reply, :encode, :error],
              %{count: 1},
              %{error: reason, stage: :incomplete_transfer}
            )

            state
            |> reset_blocks()
            |> reply_to_client(message)
        end

      {:error, reason} ->
        execute_connection_event(
          state,
          [:reply, :build, :error],
          %{count: 1},
          %{error: reason, stage: :incomplete_transfer}
        )

        state
        |> reset_blocks()
        |> reply_to_client(message)
    end
  end

  defp incomplete_transfer_reply(message) do
    Message.response(message, code: :request_entity_incomplete, type: :ack)
  end

  defp resend_cached_reply(state, reply, message) do
    if reply do
      send_reply(state, reply, %{cached: true, stage: :resend})
    end

    reply_to_client(state, message)
  end

  defp request_state(state, message, from) do
    caller = {message.token, from}

    state
    |> push_caller(caller)
    |> push_id(message)
    |> push_token(message)
  end

  defp connection_name(args, ip, port) do
    Keyword.get(args, :name, {:global, {__MODULE__, Macrina.conn_name(ip, port)}})
  end

  defp connection_state(handler, ip, port, socket) do
    %Connection{
      callers: [],
      exchange: %Macrina.Exchange{},
      handler: handler,
      ip: ip,
      port: port,
      socket: socket
    }
  end

  defp log_continue(state, message) do
    measurements = %{
      block_number: message.descriptive_block.number,
      block_size: message.descriptive_block.size,
      count: 1
    }

    metadata = %{code: message.code, more: true, type: message.type}

    execute_connection_event(state, [:block, :continue], measurements, metadata)
  end

  defp log_resend_completed(state, message) do
    measurements = %{count: 1}
    metadata = %{code: message.code, stage: :completed_transfer, type: message.type}

    execute_connection_event(state, [:reply, :resent], measurements, metadata)
  end

  defp log_incomplete_transfer(state, message) do
    measurements = %{count: 1}
    metadata = %{code: message.code, type: message.type}

    execute_connection_event(state, [:block, :incomplete], measurements, metadata)
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
