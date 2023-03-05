defmodule Macrina.Connection.Server do
  use GenServer
  alias Macrina.{Connection, Message}
  import Connection, only: :functions
  require Logger

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
         |> pop_token(message)}

      {:ok, %Message{} = message} ->
        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)}

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

  defp handle(%Connection{} = state, message_or_packet) do
    state.handler.call(state, message_or_packet)
    state
  end
end
