defmodule Macrina.Endpoint do
  @moduledoc false

  # UDP socket manager. GenServer that opens a `:gen_udp` socket and spawns
  # a `Macrina.Connection.Server` per remote peer. Not a public entry point —
  # use `Macrina.Server.start_link/1` instead.

  use GenServer
  alias Macrina.{Block1, Connection.Server, ConnectionSupervisor, Router, Telemetry}

  @connection_option_keys [:block1_max_body_size, :block1_mode, :block1_preferred_block_size]

  defstruct [:handler, :socket, connection_opts: []]

  # ------------------------------------------- CLIENT ------------------------------------------- #

  def start_link(args) do
    with {:ok, normalized_args} <- normalize_block1_opts(args),
         {:ok, handler} <- fetch_opt(normalized_args, :handler),
         {:ok, port} <- fetch_opt(normalized_args, :port) do
      name = Keyword.get(args, :name, __MODULE__)
      init_args = Keyword.put(normalized_args, :handler, handler)
      init_args = Keyword.put(init_args, :port, port)

      GenServer.start_link(__MODULE__, init_args, name: name)
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

  def init(args) do
    handler = Keyword.fetch!(args, :handler)
    port = Keyword.fetch!(args, :port)

    case :gen_udp.open(port, [:binary, {:active, true}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        Telemetry.execute([:endpoint, :start], %{system_time: System.system_time()}, %{port: port})

        state = %__MODULE__{
          connection_opts: Keyword.take(args, @connection_option_keys),
          handler: handler,
          socket: socket
        }

        {:ok, state}

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

    child_args =
      [endpoint: self(), handler: state.handler, ip: ip, port: port, socket: socket]
      |> Keyword.merge(state.connection_opts)

    init_args = {Server, child_args}

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

  defp normalize_block1_opts(args) do
    if Keyword.has_key?(args, :block1) do
      with :ok <- ensure_no_raw_block1_conflict(args),
           {:ok, policy} <- Block1.new(Keyword.fetch!(args, :block1)),
           :ok <- ensure_supported_block1_mode(policy, Keyword.get(args, :handler)) do
        normalized_args =
          args
          |> Keyword.delete(:block1)
          |> Keyword.merge(Block1.to_connection_opts(policy))

        {:ok, normalized_args}
      else
        {:error, reason} -> {:error, {:invalid_block1, reason}}
      end
    else
      {:ok, args}
    end
  end

  defp ensure_no_raw_block1_conflict(args) do
    raw_keys = [:block1_max_body_size, :block1_mode, :block1_preferred_block_size]

    if Enum.any?(raw_keys, &Keyword.has_key?(args, &1)) do
      {:error, :conflicting_options}
    else
      :ok
    end
  end

  defp ensure_supported_block1_mode(%Block1{mode: :streaming}, {:router, router, _context}) do
    if Router.supports_block1_streaming?(router) do
      :ok
    else
      {:error, :streaming_requires_block1_callback}
    end
  end

  defp ensure_supported_block1_mode(%Block1{}, _handler) do
    :ok
  end

  defp safe_call(endpoint, message) do
    case GenServer.whereis(endpoint) do
      nil -> {:error, {:endpoint_unavailable, endpoint}}
      _pid -> GenServer.call(endpoint, message)
    end
  end
end
