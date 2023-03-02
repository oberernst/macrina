defmodule Macrina.Endpoint do
  use GenServer
  require Logger
  alias Macrina.{Connection.Server, ConnectionSupervisor}

  defstruct [:handler, :socket]

  # ------------------------------------------- CLIENT ------------------------------------------- #

  def start_link(args) do
    handler = Keyword.get(args, :handler, Macrina.Handler.Echo)
    name = Keyword.get(args, :name, __MODULE__)
    port = Keyword.fetch!(args, :port)
    GenServer.start_link(__MODULE__, {handler, port}, name: name)
  end

  def init({handler, port}) do
    {:ok, socket} = :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])
    Logger.info("UDP socket opened on port #{port}")
    {:ok, %__MODULE__{handler: handler, socket: socket}}
  end

  def handler(endpoint \\ __MODULE__) do
    GenServer.call(endpoint, :handler)
  end

  def socket(endpoint \\ __MODULE__) do
    GenServer.call(endpoint, :socket)
  end

  # ------------------------------------------- SERVER ------------------------------------------- #

  def handle_call(:handler, _from, state) do
    {:reply, {:ok, state.handler}, state}
  end

  def handle_call(:socket, _from, state) do
    {:reply, {:ok, state.socket}, state}
  end

  def handle_info({:udp_error, _port, :econnreset}, state) do
    Logger.error("UDP connection reset")
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, port, packet}, state) do
    conn_name = Macrina.conn_name(ip, port)
    init_args = {Server, handler: state.handler, ip: ip, port: port, socket: socket}
    Logger.debug("UDP packet received", sender: conn_name, packet: Base.encode64(packet))

    case DynamicSupervisor.start_child(ConnectionSupervisor, init_args) do
      {:ok, pid} -> send(pid, {:coap, packet})
      {:error, {:already_started, pid}} -> send(pid, {:coap, packet})
      {:error, err} -> Logger.error("failed to start Macrina.Connection", error: inspect(err))
    end

    {:noreply, state}
  end
end
