defmodule Macrina.Connection.Server do
  use GenServer, restart: :transient
  alias Macrina.{Connection, Message, Message.Opts.Block}
  import Connection, only: :functions
  require Logger

  @timeout :timer.minutes(5)

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    handler = Keyword.fetch!(args, :handler)
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)
    name = Keyword.get(args, :name, {:global, {__MODULE__, Macrina.conn_name(ip, port)}})

    state = %Connection{
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

    GenServer.start_link(__MODULE__, state, name: name)
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
    bin = Message.encode(message)
    :gen_udp.send(state.socket, {state.ip, state.port}, bin)

    {:noreply,
     state
     |> push_caller({message.token, from})
     |> push_id(message)
     |> push_token(message), @timeout}
  end

  def handle_info({:coap, packet}, %Connection{last_reply: {last_token, reply}} = state) do
    case Message.decode(packet) do
      # a multi-part upload is ongoing, add the block to existing block map,
      # reply to the remote client, then pass this message to any local clients
      # who may be waiting for it
      {:ok, %Message{descriptive_block: %Block{more: true}} = message} ->
        {:noreply,
         state
         |> push_block(message)
         |> handle(message, :continue)
         |> reply_to_client(message), @timeout}

      # a multi-part upload is supposedly finished:
      # - if we already replied to this message, send that
      # - if the upload is incomplete, send `:request_entity_incomplete` response and reset blocks
      # - if the upload *is* complete, send the application's response and reset blocks
      # - finally, always reply to any clients that may have been waiting for this message
      {:ok, %Message{descriptive_block: %Block{more: false}} = message} ->
        payload = state |> push_block(message) |> read_blocks()

        state =
          cond do
            message.token == last_token ->
              if reply, do: Connection.reply(state, reply)
              reply_to_client(state, message)

            is_nil(payload) ->
              bin =
                message
                |> Message.response(code: :request_entity_incomplete, type: :ack)
                |> Message.encode()

              Connection.reply(state, bin)

              state
              |> set_last_reply(message.token, bin)
              |> reset_blocks()
              |> reply_to_client(message)

            true ->
              full_message = %Message{message | payload: payload}

              state
              |> handle(full_message)
              |> reset_blocks()
              |> reply_to_client(full_message)
          end

        {:noreply, state, @timeout}

      # a single-datagram message was received but its token was already
      # replied to, so resend the cached reply
      {:ok, %Message{token: token} = message} when token == last_token ->
        if reply, do: Connection.reply(state, reply)
        reply_to_client(state, message)
        {:noreply, state, @timeout}

      {:ok, %Message{type: type} = message} when type in [:ack, :res] ->
        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)
         |> pop_id(message)
         |> pop_token(message), @timeout}

      {:ok, %Message{} = message} ->
        {:noreply, state |> handle(message) |> reply_to_client(message), @timeout}

      _ ->
        Logger.error("CoAP decoding failed", packet: Base.encode64(packet))
        {:noreply, state, @timeout}
    end
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
    if reply = state.handler.call(state, message) do
      bin = Message.encode(reply)

      Logger.info("#{__MODULE__}.handle/2 encoding and replying",
        conn: inspect(state),
        request: inspect(message),
        response: %{encoded: Base.encode64(bin), raw: reply}
      )

      Connection.reply(state, bin)
      set_last_reply(state, message.token, bin)
    else
      Logger.info("#{__MODULE__}.handle/2 did not reply",
        conn: inspect(state),
        request: inspect(message)
      )

      set_last_reply(state, message.token, nil)
    end
  end

  defp handle(%Connection{} = state, message, :continue) do
    bin =
      message
      |> Message.response(code: :continue, type: :ack)
      |> Message.encode()

    Logger.info("#{__MODULE__}.handle/3 continuing",
      conn: inspect(state),
      request: inspect(message)
    )

    Connection.reply(state, bin)
    state
  end
end
