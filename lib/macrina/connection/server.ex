defmodule Macrina.Connection.Server do
  use GenServer, restart: :transient
  alias Macrina.{BlockTransfer, Connection, Message, Message.Opts.Block}
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
      {:ok, %Message{descriptive_block: %Block{}} = message} ->
        handle_block_message(state, message)

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
    {state, _bin} = handle_and_capture(state, message)
    state
  end

  defp handle_and_capture(%Connection{} = state, message) do
    case state.handler.call(state, message) do
      nil ->
        Logger.info("#{__MODULE__}.handle/2 did not reply",
          conn: inspect(state),
          request: inspect(message)
        )

        {set_last_reply(state, message.token, nil), nil}

      reply ->
        bin = Message.encode(reply)

        Logger.info("#{__MODULE__}.handle/2 encoding and replying",
          conn: inspect(state),
          request: inspect(message),
          response: %{encoded: Base.encode64(bin), raw: reply}
        )

        Connection.reply(state, bin)
        {set_last_reply(state, message.token, bin), bin}
    end
  end

  defp handle_block_message(%Connection{} = state, %Message{} = message) do
    case BlockTransfer.handle_block(state.ip, message.token, state.handler, message) do
      {:continue, ack_bin} ->
        Connection.reply(state, ack_bin)
        {:noreply, reply_to_client(state, message), @timeout}

      {:assembled, full_message} ->
        {state, reply_bin} = handle_and_capture(state, full_message)
        BlockTransfer.cache_completion(state.ip, message.token, reply_bin)
        {:noreply, reply_to_client(state, full_message), @timeout}

      {:incomplete, ack_bin} ->
        Connection.reply(state, ack_bin)
        {:noreply, reply_to_client(state, message), @timeout}

      {:duplicate, nil} ->
        {:noreply, reply_to_client(state, message), @timeout}

      {:duplicate, bin} when is_binary(bin) ->
        Connection.reply(state, bin)
        {:noreply, reply_to_client(state, message), @timeout}
    end
  end
end
