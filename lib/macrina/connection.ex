defmodule Macrina.Connection do
  use GenServer
  alias Macrina.{ConnectionRegistry, Handler, Message}
  require Logger

  defstruct [:callers, :handler, :ids, :ip, :name, :port, :socket, :tokens]

  @type t :: %__MODULE__{
          handler: module(),
          ip: tuple(),
          name: String.t(),
          port: integer(),
          socket: port()
        }

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    handler = Keyword.get(args, :handler, Handler)
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)
    name = {:via, Registry, {ConnectionRegistry, Macrina.conn_name(ip, port)}}

    state = %__MODULE__{
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
    {:ok, state}
  end

  def handle_call(
        {:request, %Message{token: token} = message},
        from,
        %__MODULE__{callers: callers} = state
      ) do
    :gen_udp.send(state.socket, {state.ip, state.port}, Message.encode(message))
    {:noreply, %__MODULE__{state | callers: [{token, from} | callers]}}
  end

  def handle_info(
        {:coap, packet},
        %__MODULE__{callers: callers, handler: handler, ids: ids, tokens: tokens} = state
      ) do
    case Message.decode(packet) do
      {:ok, %Message{message_id: id, token: token, type: :ack} = message} ->
        Logger.info("#{state.port} received ACK #{:binary.encode_hex(packet)}")

        ids = List.delete(ids, id)
        tokens = List.delete(tokens, token)

        :ok = handler.call(state, message)
        callers = reply_to_client(callers, message)

        {:noreply, %__MODULE__{state | callers: callers, ids: ids, tokens: tokens}}

      {:ok, %Message{message_id: id, token: token, type: :con} = message} ->
        Logger.info("#{state.port} received CON #{:binary.encode_hex(packet)}")

        :ok = handler.call(state, message)
        callers = reply_to_client(callers, message)
        state = %__MODULE__{state | callers: callers, ids: [id | ids], tokens: [token | tokens]}

        {:noreply, state}

      {:ok, %Message{token: token, type: :non} = message} ->
        Logger.info("#{state.port} received NON #{:binary.encode_hex(packet)}")

        :ok = handler.call(state, message)
        callers = reply_to_client(callers, message)

        {:noreply, %__MODULE__{state | callers: callers, tokens: [token | tokens]}}

      {:ok, %Message{message_id: id, token: token, type: :res} = message} ->
        Logger.info("#{state.port} received RES #{:binary.encode_hex(packet)}")

        ids = List.delete(ids, id)
        tokens = List.delete(tokens, token)

        :ok = handler.call(state, message)
        callers = reply_to_client(callers, message)

        {:noreply, %__MODULE__{state | callers: callers, ids: ids, tokens: tokens}}
    end
  end

  defp reply_to_client(callers, message) do
    caller = Enum.find(callers, fn {t, _from} -> t == message.token end)

    unless is_nil(caller) do
      {_, from} = caller
      GenServer.reply(from, message)
    end

    List.delete(callers, caller)
  end
end
