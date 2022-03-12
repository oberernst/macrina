defmodule Macrina.Endpoint do
  use GenServer
  alias Macrina.{Connection, ConnectionRegistry, ConnectionSupervisor, Message}

  def start_link(args) do
    handler = Keyword.get(args, :handler, &echo/2)
    port = Keyword.fetch!(args, :port)
    GenServer.start_link(__MODULE__, {handler, port})
  end

  def init({handler, port}) do
    {:ok, _socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])
    {:ok, handler}
  end

  def handle_info({:udp, socket, ip, port, packet}, handler) do
    case Registry.lookup(ConnectionRegistry, Connection.name(ip, port)) do
      [{pid, _}] ->
        send(pid, {:coap, packet})

      _ ->
        init_args = {Connection, handler: handler, ip: ip, port: port, socket: socket}
        {:ok, pid} = DynamicSupervisor.start_child(ConnectionSupervisor, init_args)
        send(pid, {:coap, packet})
    end

    {:noreply, nil}
  end

  @spec echo(Connection.t(), Message.t()) :: :ok | {:error, term()}
  def echo(
        %Connection{ip: ip, port: port, socket: socket} = _connection,
        %Message{type: :confirmable} = message
      ) do
    :gen_udp.send(socket, {ip, port}, Message.encode(message))
  end

  def echo(_, _), do: :ok
end
