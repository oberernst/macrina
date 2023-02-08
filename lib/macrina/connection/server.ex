defmodule Macrina.Connection.Server do
  use GenServer
  alias Macrina.{Connection, Handler.Echo, Message}
  import Connection, only: :functions
  require Logger

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    handler = Keyword.get(args, :handler, Echo)
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)
    name = Keyword.get(args, :name, {:global, {__MODULE__, Macrina.conn_name(ip, port)}})

    state = %Connection{
      callers: [],
      handler: handler,
      ids: [],
      ip: ip,
      port: port,
      tokens: [],
      seen_ids: [],
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
    {:ok, state}
  end

  def handle_call({:request, %Message{} = message}, from, %Connection{} = state) do
    bin = Message.encode(message)
    :gen_udp.send(state.socket, {state.ip, state.port}, bin)

    {:noreply,
     state
     |> push_caller({message.token, from})
     |> push_id(message)
     |> push_token(message)}
  end

  def handle_info({:coap, packet}, %Connection{} = state) do
    case Message.decode(packet) do
      {:ok, %Message{type: type} = message} when type in [:ack, :res] ->
        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)
         |> pop_id(message)
         |> pop_token(message)
         |> push_seen_id(message)}

      {:ok, %Message{} = message} ->
        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)
         |> push_seen_id(message)}

      _ ->
        Logger.error("CoAP decoding failed", packet: Base.encode64(packet))
        handle(state, packet)
        {:noreply, state}
    end
  end

  defp reply_to_client(%Connection{callers: callers} = state, message) do
    caller = Enum.find(callers, fn {t, _from} -> t == message.token end)

    unless is_nil(caller) do
      {_, from} = caller
      GenServer.reply(from, message)
    end

    pop_caller(state, caller)
  end

  defp handle(%Connection{handler: handler} = state, %Message{} = message) do
    if message.id in state.seen_ids do
      state
    else
      handler.call(state, message)
      state
    end
  end

  defp handle(state, packet) when is_binary(packet) do
    state.handler.call(state, packet)
  end
end
