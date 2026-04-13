defmodule Macrina.Endpoint do
  use GenServer
  alias Macrina.{Connection.Server, ConnectionSupervisor, Telemetry}

  defstruct [:handler, :socket]

  # ------------------------------------------- CLIENT ------------------------------------------- #

  def start_link(args) do
    with {:ok, handler} <- fetch_opt(args, :handler),
         {:ok, port} <- fetch_opt(args, :port) do
      name = Keyword.get(args, :name, __MODULE__)
      GenServer.start_link(__MODULE__, {handler, port}, name: name)
    end
  end

  def start_link!(args) do
    case start_link(args) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        raise ArgumentError, "invalid endpoint start options: #{inspect(reason)}"
    end
  end

  def init({handler, port}) do
    case :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        Telemetry.execute([:endpoint, :start], %{system_time: System.system_time()}, %{port: port})

        {:ok, %__MODULE__{handler: handler, socket: socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handler(endpoint \\ __MODULE__) do
    safe_call(endpoint, :handler)
  end

  def socket(endpoint \\ __MODULE__) do
    safe_call(endpoint, :socket)
  end

  # ------------------------------------------- SERVER ------------------------------------------- #

  def handle_call(:handler, _from, state) do
    {:reply, {:ok, state.handler}, state}
  end

  def handle_call(:socket, _from, state) do
    {:reply, {:ok, state.socket}, state}
  end

  def handle_info({:udp_error, _port, :econnreset}, state) do
    Telemetry.execute([:endpoint, :udp, :error], %{count: 1}, %{reason: :econnreset})
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, port, packet}, state) do
    conn_name = Macrina.conn_name(ip, port)
    init_args = {Server, handler: state.handler, ip: ip, port: port, socket: socket}

    Telemetry.execute(
      [:endpoint, :packet, :received],
      %{bytes: byte_size(packet)},
      %{peer: conn_name, ip: ip, port: port}
    )

    case DynamicSupervisor.start_child(ConnectionSupervisor, init_args) do
      {:ok, pid} ->
        send(pid, {:coap, packet})

      {:error, {:already_started, pid}} ->
        send(pid, {:coap, packet})

      {:error, err} ->
        Telemetry.execute(
          [:endpoint, :connection, :start, :error],
          %{count: 1},
          %{error: err, peer: conn_name}
        )
    end

    {:noreply, state}
  end

  defp fetch_opt(args, key) do
    case Keyword.fetch(args, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp safe_call(endpoint, message) do
    case GenServer.whereis(endpoint) do
      nil -> {:error, {:endpoint_unavailable, endpoint}}
      _pid -> GenServer.call(endpoint, message)
    end
  end
end
