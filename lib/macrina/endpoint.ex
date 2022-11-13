defmodule Macrina.Endpoint do
  use GenServer
  alias Macrina.{Connection.Server, ConnectionRegistry, ConnectionSupervisor}

  defstruct [:handler, :socket]

  def start_link(args) do
    handler = Keyword.get(args, :handler, Macrina.Handler.Echo)
    name = Keyword.get(args, :name, __MODULE__)
    port = Keyword.fetch!(args, :port)
    GenServer.start_link(__MODULE__, {handler, port}, name: name)
  end

  def init({handler, port}) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])
    {:ok, %__MODULE__{handler: handler, socket: socket}}
  end

  def socket(endpoint \\ __MODULE__) do
    GenServer.call(endpoint, :socket)
  end

  def handle_call(:socket, _from, state) do
    {:reply, {:ok, state.socket}, state}
  end

  def handle_info({:udp_error, _port, :econnreset}, state) do
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, port, packet}, state) do
    conn_name = Macrina.conn_name(ip, port)

    case Registry.lookup(ConnectionRegistry, conn_name) do
      [{pid, _}] ->
        send(pid, {:coap, packet})

      _ ->
        init_args = {
          Server,
          handler: state.handler, ip: ip, name: conn_name, port: port, socket: socket
        }

        {:ok, pid} = DynamicSupervisor.start_child(ConnectionSupervisor, init_args)
        send(pid, {:coap, packet})
    end

    {:noreply, state}
  end
end
