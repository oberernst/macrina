defmodule Macrina.Connection.Server do
  use GenServer, restart: :transient
  alias Macrina.{Connection, Handler, Message, Message.Opts.Block}
  import Connection, only: :functions
  require Logger

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
    Logger.info("Macrina connection started", state: inspect(state))
    {:ok, state, @timeout}
  end

  def handle_call({:request, %Message{} = message}, from, %Connection{} = state) do
    case Message.encode(message) do
      {:ok, packet} ->
        next_state = request_state(state, message, from)

        :gen_udp.send(state.socket, {state.ip, state.port}, packet)

        {:noreply, next_state, @timeout}

      {:error, reason} ->
        error = {:encode_failed, reason}
        GenServer.reply(from, {:error, error})

        {:noreply, state, @timeout}
    end
  end

  def handle_info({:coap, packet}, %Connection{last_reply: {last_token, reply}} = state) do
    decoded = Message.decode(packet)
    next_state = next_packet_state(decoded, state, last_token, reply)

    {:noreply, next_state, @timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def terminate(:normal, state) do
    Logger.info("Connection server shutting down", server: Macrina.conn_name(state.ip, state.port))
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
          Logger.info("#{__MODULE__}.handle/2 encoding and replying",
            conn: inspect(state),
            request: inspect(message),
            response: %{encoded: Base.encode64(bin), raw: reply}
          )

          Connection.reply(state, bin)
          set_last_reply(state, message.token, bin)

        {:error, reason} ->
          Logger.error("#{__MODULE__}.handle/2 failed to encode reply",
            conn: inspect(state),
            reason: inspect(reason),
            request: inspect(message),
            response: inspect(reply)
          )

          set_last_reply(state, message.token, nil)
      end
    else
      Logger.info("#{__MODULE__}.handle/2 did not reply",
        conn: inspect(state),
        request: inspect(message)
      )

      set_last_reply(state, message.token, nil)
    end
  end

  defp handle(%Connection{} = state, message, :continue) do
    case Message.response(message, code: :continue, type: :ack) do
      {:ok, continue_message} ->
        case Message.encode(continue_message) do
          {:ok, bin} ->
            Logger.info("#{__MODULE__}.handle/3 continuing",
              conn: inspect(state),
              request: inspect(message)
            )

            Connection.reply(state, bin)
            state

          {:error, reason} ->
            Logger.error("#{__MODULE__}.handle/3 failed to encode continue reply",
              conn: inspect(state),
              reason: inspect(reason),
              request: inspect(message)
            )

            state
        end

      {:error, reason} ->
        Logger.error("#{__MODULE__}.handle/3 failed to build continue reply",
          conn: inspect(state),
          reason: inspect(reason),
          request: inspect(message)
        )

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
    Logger.error("CoAP decoding failed")
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

        Logger.info("#{__MODULE__}.handle_info/2 completed block transfer",
          conn: inspect(state),
          request: inspect(full_message)
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
            Connection.reply(state, encoded_reply)

            state
            |> set_last_reply(message.token, encoded_reply)
            |> reset_blocks()
            |> reply_to_client(message)

          {:error, reason} ->
            Logger.error("#{__MODULE__}.reply_incomplete_transfer/2 failed to encode reply",
              conn: inspect(state),
              reason: inspect(reason),
              request: inspect(message)
            )

            state
            |> reset_blocks()
            |> reply_to_client(message)
        end

      {:error, reason} ->
        Logger.error("#{__MODULE__}.reply_incomplete_transfer/2 failed to build reply",
          conn: inspect(state),
          reason: inspect(reason),
          request: inspect(message)
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
    if reply, do: Connection.reply(state, reply)

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
      blocks: %{},
      callers: [],
      handler: handler,
      ids: [],
      ip: ip,
      last_reply: {nil, nil},
      port: port,
      tokens: [],
      socket: socket
    }
  end

  defp log_continue(state, message) do
    Logger.info("#{__MODULE__}.handle_info/2 continuing block transfer",
      conn: inspect(state),
      request: inspect(message)
    )
  end

  defp log_resend_completed(state, message) do
    Logger.info("#{__MODULE__}.handle_info/2 resending cached reply for completed block transfer",
      conn: inspect(state),
      request: inspect(message)
    )
  end

  defp log_incomplete_transfer(state, message) do
    Logger.info("#{__MODULE__}.handle_info/2 incomplete block transfer",
      conn: inspect(state),
      request: inspect(message)
    )
  end

  defp fetch_opt(args, key) do
    case Keyword.fetch(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
