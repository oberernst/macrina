defmodule Macrina.Endpoint do
  @moduledoc false

  # Endpoint socket manager. GenServer that opens a transport (default
  # `Macrina.Transport.UDP`) and spawns a `Macrina.Peer.Session` per
  # remote peer. Not a public entry point — use
  # `Macrina.Server.start_link/1` instead.

  use GenServer
  alias Macrina.{Block1, ConnectionSupervisor, Peer.Session, Router, Telemetry, Transport}

  @connection_option_keys [:block1_max_body_size, :block1_mode, :block1_preferred_block_size]
  @message_id_modulus 65_536

  defstruct [:handler, :message_id_counter, :socket, :transport, connection_opts: []]

  # ------------------------------------------- CLIENT ------------------------------------------- #

  def start_link(args) do
    with {:ok, args} <- normalize_router_opt(args),
         {:ok, normalized_args} <- normalize_block1_opts(args),
         {:ok, handler} <- fetch_opt(normalized_args, :handler),
         {:ok, port} <- fetch_opt(normalized_args, :port) do
      name = Keyword.get(args, :name, __MODULE__)
      init_args = Keyword.put(normalized_args, :handler, handler)
      init_args = Keyword.put(init_args, :port, port)

      GenServer.start_link(__MODULE__, init_args, name: name)
    end
  end

  defp normalize_router_opt(args) do
    case Keyword.get(args, :router) do
      nil ->
        {:error, {:missing_option, :router}}

      router when is_atom(router) ->
        context = Keyword.get(args, :context, %{})

        normalized =
          args
          |> Keyword.put(:handler, {router, context})
          |> Keyword.delete(:router)
          |> Keyword.delete(:context)

        {:ok, normalized}

      other ->
        {:error, {:invalid_router, other}}
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
    transport = Keyword.get(args, :transport, Transport.UDP)

    case transport.open(port: port, active: true) do
      {:ok, socket} ->
        Telemetry.execute([:endpoint, :start], %{system_time: System.system_time()}, %{port: port})

        state = %__MODULE__{
          connection_opts: Keyword.take(args, @connection_option_keys),
          handler: handler,
          message_id_counter: new_message_id_counter(),
          socket: socket,
          transport: transport
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Per-endpoint atomic counter, replacing the prior `Enum.random(10000..19999)`
  # default. Seeded with a random initial value so two endpoints in the same
  # VM that happen to talk to overlapping peers don't collide on their first
  # outbound message id. RFC 7252 §4.4 only requires monotonic-with-wrap
  # within a single conversation; the seed avoids cross-endpoint birthday
  # collisions cheaply.
  defp new_message_id_counter do
    ref = :atomics.new(1, signed: false)
    :atomics.put(ref, 1, :rand.uniform(@message_id_modulus) - 1)
    ref
  end

  @doc """
  Returns the next CoAP message id for an endpoint counter, wrapping at
  2^16. Pure helper that takes the `:atomics` ref directly so the caller
  doesn't have to round-trip through a `GenServer.call`.
  """
  @spec next_message_id(:atomics.atomics_ref()) :: 0..65_535
  def next_message_id(ref) do
    rem(:atomics.add_get(ref, 1, 1), @message_id_modulus)
  end

  @doc """
  Fetches the per-endpoint message-id atomics ref. `Macrina.Client.build/3`
  uses this once at connection setup so each `Macrina.Peer.Session` can
  bump the counter without further IPC.
  """
  @spec message_id_counter(GenServer.server()) :: {:ok, :atomics.atomics_ref()} | {:error, term()}
  def message_id_counter(endpoint \\ __MODULE__) do
    safe_call(endpoint, :message_id_counter)
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

  def handle_call(:message_id_counter, _from, state) do
    {:reply, {:ok, state.message_id_counter}, state}
  end

  def handle_call(:socket, _from, state) do
    {:reply, {:ok, state.socket}, state}
  end

  def handle_info({:udp_error, _port, :econnreset}, state) do
    Telemetry.execute([:endpoint, :udp, :error], %{count: 1}, %{reason: :econnreset})
    {:noreply, state}
  end

  def handle_info({:udp, socket, ip, port, packet}, state) do
    conn_name = Macrina.Peer.label(ip, port)
    {router, context} = state.handler

    child_args =
      [
        endpoint: self(),
        router: router,
        context: context,
        ip: ip,
        message_id_counter: state.message_id_counter,
        port: port,
        socket: socket,
        transport: state.transport
      ]
      |> Keyword.merge(state.connection_opts)

    init_args = {Session, child_args}

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

  defp ensure_supported_block1_mode(%Block1{mode: :streaming}, {router, _context})
       when is_atom(router) do
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
