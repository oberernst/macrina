defmodule Macrina.Connection.Server do
  use GenServer
  alias Macrina.{Connection, ConnectionRegistry, Handler.Echo, Message}
  import Connection, only: :functions
  require Logger

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    handler = Keyword.get(args, :handler, Echo)
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)
    name = {:via, Registry, {ConnectionRegistry, Macrina.conn_name(ip, port)}}

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
    {:ok, state}
  end

  def handle_call({:request, %Message{} = message}, from, %Connection{port: port} = state) do
    bin = Message.encode(message)
    Logger.info("#{port} sending #{message.type} #{Base.encode64(bin)}")
    :gen_udp.send(state.socket, {state.ip, state.port}, bin)

    {:noreply,
     state
     |> push_caller({message.token, from})
     |> push_id(message)
     |> push_token(message)}
  end

  def handle_info({:coap, packet}, %Connection{port: port} = state) do
    case Message.decode(packet) do
      {:ok, %Message{type: type} = message} when type in [:ack, :res] ->
        Logger.info("#{port} received #{type} #{Base.encode64(packet)}")

        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)
         |> pop_id(message)
         |> pop_token(message)
         |> push_seen_id(message)}

      {:ok, %Message{type: type} = message} ->
        Logger.info("#{port} received #{type} #{Base.encode64(packet)}")

        {:noreply,
         state
         |> handle(message)
         |> reply_to_client(message)
         |> push_seen_id(message)}
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

  defp handle(%Connection{handler: handler} = state, message) do
    if message.id in state.seen_ids do
      state
    else
      handler.call(state, message)
      state
    end
  end
end
