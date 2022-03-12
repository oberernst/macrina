defmodule Macrina.Endpoint do
  use GenServer
  alias Macrina.{Connection, ConnectionRegistry, ConnectionSupervisor}

  def start_link(port), do: GenServer.start_link(__MODULE__, port)
  def init(port), do: :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

  def handle_info({:udp, socket, ip, port, packet}, _) do
    case Registry.lookup(ConnectionRegistry, Connection.name(ip, port)) do
      [{pid, _}] ->
        send(pid, {:coap, packet})

      _ ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            ConnectionSupervisor,
            {Connection, ip: ip, port: port, socket: socket}
          )

        send(pid, {:coap, packet})
    end

    {:noreply, nil}
  end
end
