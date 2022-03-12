defmodule Macrina.Connection do
  use GenServer
  alias Macrina.{ConnectionRegistry, Request}
  require Logger

  defstruct [:handler, :ip, :port, :socket]

  @type t :: %__MODULE__{
          handler: (t(), binary() -> :ok | {:error, term()}),
          ip: tuple(),
          port: integer(),
          socket: port()
        }

  # ------------------------------------------- Client ------------------------------------------- #

  def start_link(args) do
    # validate args
    handler = Keyword.fetch!(args, :handler)
    ip = Keyword.fetch!(args, :ip)
    port = Keyword.fetch!(args, :port)
    socket = Keyword.fetch!(args, :socket)

    # marshall genserver requirements
    name = {:via, Registry, {ConnectionRegistry, name(ip, port)}}
    state = %__MODULE__{handler: handler, ip: ip, port: port, socket: socket}

    # start the genserver
    GenServer.start_link(__MODULE__, state, name: name)
  end

  @spec name(tuple(), integer()) :: String.t()
  def name({_, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(".") |> append_port(port)
  end

  def name({_, _, _, _, _, _, _, _} = ip, port) do
    ip |> Tuple.to_list() |> Enum.join(":") |> append_port(port)
  end

  @spec name(t()) :: String.t()
  def name(%__MODULE__{ip: ip, port: port}) do
    name(ip, port)
  end

  # ------------------------------------------- Server ------------------------------------------- #

  def init(state) do
    {:ok, state}
  end

  def handle_info({:coap, packet}, %__MODULE__{handler: handler} = state) do
    case Request.decode(packet) do
      {:ok, request} ->
        handler.(state, request)

      _ ->
        Logger.error("message failed to decode: #{packet}")
    end

    {:noreply, state}
  end

  defp append_port(ip_string, port) do
    ip_string <> "/" <> "#{port}"
  end
end
