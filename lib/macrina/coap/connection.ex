defmodule Macrina.CoAP.Connection do
  use GenServer

  alias Macrina.CoAP.{ConnectionRegistry, Request, Response}
  require Logger

  defstruct [:handler, :ip, :port, :socket, :token]

  @type t :: %__MODULE__{
          handler: (t(), binary() -> :ok | {:error, term()}),
          ip: tuple(),
          port: integer(),
          socket: port(),
          token: binary()
        }

  def start_link(args) do
    # validate args
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)

    # marshall genserver requirements
    name = {:via, Registry, {ConnectionRegistry, name(ip, port)}}
    state = %__MODULE__{ip: ip, port: port, socket: socket}

    # start the genserver
    GenServer.start_link(__MODULE__, state, name: name)
  end

  def name({_, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(".") |> append_port(port)
  end

  def name({_, _, _, _, _, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(":") |> append_port(port)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_info({:coap, packet}, state) do
    {:ok, request} = Request.decode(packet)
    request |> Response.ack() |> Request.decode() |> inspect() |> Logger.info()
    {:noreply, state}
  end

  def name(%__MODULE__{ip: ip, port: port}) do
    name(ip, port)
  end

  defp append_port(ip_string, port) do
    ip_string <> "/" <> "#{port}"
  end
end
