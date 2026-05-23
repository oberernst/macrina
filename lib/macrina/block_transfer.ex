defmodule Macrina.BlockTransfer do
  @moduledoc false

  use GenServer, restart: :transient

  require Logger

  alias Macrina.{Blocks, Message}
  alias Macrina.Message.Opts.Block

  @assembling_timeout :timer.minutes(5)
  @complete_timeout :timer.seconds(247)

  defstruct [
    :handler,
    :blocks,
    :last_reply,
    :phase,
    :peers,
    :uri_path,
    :uri_query,
    :request_tag,
    :discriminator
  ]

  @type peer :: {:inet.ip_address(), :inet.port_number()}

  @type t :: %__MODULE__{
          handler: module(),
          blocks: Blocks.acc(),
          last_reply: binary() | nil,
          phase: :assembling | :complete,
          peers: [peer()],
          uri_path: [String.t()],
          uri_query: [String.t()],
          request_tag: binary() | nil,
          discriminator: binary()
        }

  def start_link(args) do
    init_arg = %{
      ip: Keyword.fetch!(args, :ip),
      port: Keyword.fetch!(args, :port),
      uri_path: Keyword.fetch!(args, :uri_path),
      uri_query: Keyword.fetch!(args, :uri_query),
      request_tag: Keyword.fetch!(args, :request_tag),
      discriminator: Keyword.fetch!(args, :discriminator),
      handler: Keyword.fetch!(args, :handler)
    }

    GenServer.start_link(__MODULE__, init_arg, Keyword.take(args, [:name]))
  end

  @spec handle_block(pid(), :inet.port_number(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(pid, port, %Message{} = message) when is_pid(pid) and is_integer(port) do
    GenServer.call(pid, {:block, port, message})
  end

  @spec handle_block(:inet.ip_address(), :inet.port_number(), module(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(ip, port, handler, %Message{} = message) do
    ip
    |> lookup_or_start(port, handler, message)
    |> handle_block(port, message)
  end

  defp lookup_or_start(ip, port, handler, %Message{} = message) do
    {path, query, discriminator} = correlation_parts(message)

    case :global.whereis_name(global_name(ip, path, query, discriminator)) do
      pid when is_pid(pid) -> pid
      :undefined -> start_under_supervisor(ip, port, handler, path, query, message)
    end
  end

  defp start_under_supervisor(ip, port, handler, path, query, %Message{} = message) do
    {_, _, discriminator} = correlation_parts(message)
    tag = extract_tag(message.options)

    args = [
      ip: ip,
      port: port,
      handler: handler,
      uri_path: path,
      uri_query: query,
      request_tag: tag,
      discriminator: discriminator,
      name: {:global, global_name(ip, path, query, discriminator)}
    ]

    case DynamicSupervisor.start_child(Macrina.BlockTransfer.Supervisor, {__MODULE__, args}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp global_name(ip, path, query, discriminator) do
    {__MODULE__, ip, path, query, discriminator}
  end

  @doc false
  @spec cache_completion(pid(), binary() | nil) :: :ok
  def cache_completion(pid, reply_bin) when is_pid(pid) do
    GenServer.call(pid, {:cache_completion, reply_bin})
  end

  @spec cache_completion(:inet.ip_address(), Message.t(), binary() | nil) :: :ok
  def cache_completion(ip, %Message{} = message, reply_bin) do
    {path, query, discriminator} = correlation_parts(message)

    case :global.whereis_name(global_name(ip, path, query, discriminator)) do
      :undefined -> :ok
      pid -> cache_completion(pid, reply_bin)
    end
  end

  @impl true
  def init(%{
        ip: ip,
        port: port,
        uri_path: path,
        uri_query: query,
        request_tag: tag,
        discriminator: discriminator,
        handler: handler
      }) do
    state = %__MODULE__{
      handler: handler,
      blocks: Blocks.empty(),
      last_reply: nil,
      phase: :assembling,
      peers: [{ip, port}],
      uri_path: path,
      uri_query: query,
      request_tag: tag,
      discriminator: discriminator
    }

    Logger.info("[BlockTransfer] started", peer: peer_id(state), op: op_id(state))
    {:ok, state, @assembling_timeout}
  end

  @impl true
  def handle_call(
        {:block, port, %Message{descriptive_block: %Block{} = b} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      )
      when b.more == true do
    state = record_peer(state, port)
    blocks = Blocks.push(state.blocks, message)

    Logger.info("[BlockTransfer] block accepted",
      peer: peer_id(state),
      op: op_id(state),
      block: b.number,
      size: byte_size(message.payload),
      more: true
    )

    ack_bin = message |> Message.response(code: :continue, type: :ack) |> Message.encode()
    {:reply, {:continue, ack_bin}, %{state | blocks: blocks}, @assembling_timeout}
  end

  def handle_call(
        {:block, port, %Message{descriptive_block: %Block{more: false} = b} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    state = record_peer(state, port)
    blocks = Blocks.push(state.blocks, message)

    Logger.info("[BlockTransfer] block accepted",
      peer: peer_id(state),
      op: op_id(state),
      block: b.number,
      size: byte_size(message.payload),
      more: false
    )

    case Blocks.read(blocks) do
      {:ok, payload} ->
        Logger.info("[BlockTransfer] blocks assembled",
          peer: peer_id(state),
          op: op_id(state),
          count: map_size(blocks),
          total_size: byte_size(payload)
        )

        full = %Message{message | payload: payload}
        {:reply, {:assembled, full}, %{state | blocks: blocks}, @assembling_timeout}

      {:error, {:missing, n}} ->
        Logger.info("[BlockTransfer] blocks incomplete",
          peer: peer_id(state),
          op: op_id(state),
          missing: n,
          have: map_size(blocks)
        )

        bin =
          message
          |> Message.response(code: :request_entity_incomplete, type: :ack)
          |> Message.encode()

        {:reply, {:incomplete, bin}, %{state | blocks: blocks}, @assembling_timeout}
    end
  end

  def handle_call(
        {:block, port, %Message{descriptive_block: %Block{more: false}}},
        _from,
        %__MODULE__{phase: :complete, last_reply: reply_bin} = state
      ) do
    state = record_peer(state, port)

    Logger.info("[BlockTransfer] duplicate final block, replaying cached reply",
      peer: peer_id(state),
      op: op_id(state),
      cached: not is_nil(reply_bin)
    )

    {:reply, {:duplicate, reply_bin}, state, @complete_timeout}
  end

  def handle_call(
        {:cache_completion, reply_bin},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    reply_size = if is_binary(reply_bin), do: byte_size(reply_bin), else: 0

    Logger.info("[BlockTransfer] completion cached",
      peer: peer_id(state),
      op: op_id(state),
      reply_size: reply_size
    )

    {:reply, :ok, %{state | last_reply: reply_bin, phase: :complete}, @complete_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("[BlockTransfer] timeout, shutting down",
      peer: peer_id(state),
      op: op_id(state),
      phase: state.phase
    )

    {:stop, :normal, state}
  end

  # RFC 9175 §3.2: Request-Tag is the body identifier when present. When absent,
  # fall back to the request Token — pre-9175 clients that hold the Token stable
  # across the blocks of a body (e.g. NCS 2.2.54) keep working, and a subsequent
  # body with a new Token gets a fresh buffer instead of colliding with this one.
  defp correlation_parts(%Message{options: options, token: token}) do
    path = extract_path(options)
    query = extract_query(options)
    tag = extract_tag(options)
    {path, query, tag || token}
  end

  defp extract_path(options) do
    for {"Uri-Path", v} <- options, do: v
  end

  defp extract_query(options) do
    for {"Uri-Query", v} <- options, do: v
  end

  defp extract_tag(options) do
    case List.keyfind(options, "Request-Tag", 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  defp record_peer(%__MODULE__{peers: [{ip, _} | _] = peers} = state, port) do
    new = {ip, port}
    if new in peers, do: state, else: %{state | peers: peers ++ [new]}
  end

  defp peer_id(%__MODULE__{peers: peers}) do
    Enum.map_join(peers, ",", fn {ip, port} -> "#{:inet.ntoa(ip)}:#{port}" end)
  end

  defp op_id(%__MODULE__{uri_path: path, uri_query: query} = state) do
    base = "/" <> Enum.join(path, "/")
    base = if query == [], do: base, else: base <> "?" <> Enum.join(query, "&")
    sep = if is_binary(state.request_tag), do: "#tag=", else: "#tok="
    base <> sep <> Base.encode16(state.discriminator, case: :lower)
  end
end
