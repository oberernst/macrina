defmodule Macrina.CoAP.Endpoint do
  use GenServer
  alias Macrina.CoAP.Request
  require Logger

  def start_link(port), do: GenServer.start_link(__MODULE__, port)
  def init(port), do: :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}])

  def handle_info({:udp, _socket, _ip, _port, packet}, socket) do
    packet |> Request.decode() |> inspect() |> Logger.info()
    {:noreply, socket}
  end
end
