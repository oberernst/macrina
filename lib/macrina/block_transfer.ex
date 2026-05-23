defmodule Macrina.BlockTransfer do
  @moduledoc false

  use GenServer, restart: :transient

  require Logger

  alias Macrina.{Blocks, Message, Registry}
  alias Macrina.Message.Opts.Block

  @assembling_timeout :timer.minutes(5)
  @complete_timeout :timer.seconds(247)

  defstruct [:ip, :token, :handler, :blocks, :last_reply, :phase]

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          token: binary(),
          handler: module(),
          blocks: Blocks.acc(),
          last_reply: binary() | nil,
          phase: :assembling | :complete
        }

  def start_link(args) do
    init_arg = %{
      ip: Keyword.fetch!(args, :ip),
      token: Keyword.fetch!(args, :token),
      handler: Keyword.fetch!(args, :handler)
    }

    GenServer.start_link(__MODULE__, init_arg, Keyword.take(args, [:name]))
  end

  @spec handle_block(pid(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(pid, %Message{} = message) do
    GenServer.call(pid, {:block, message})
  end

  @spec handle_block(pid(), :inet.ip_address(), binary(), module(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(endpoint, ip, token, handler, %Message{} = message)
      when is_pid(endpoint) do
    endpoint
    |> lookup_or_start(ip, token, handler)
    |> handle_block(message)
  end

  defp lookup_or_start(endpoint, ip, token, handler) do
    case Registry.whereis(endpoint, {:block_transfer, ip, token}) do
      pid when is_pid(pid) -> pid
      nil -> start_under_supervisor(endpoint, ip, token, handler)
    end
  end

  defp start_under_supervisor(endpoint, ip, token, handler) do
    args = [
      ip: ip,
      token: token,
      handler: handler,
      name: Registry.via(endpoint, {:block_transfer, ip, token})
    ]

    case DynamicSupervisor.start_child(Macrina.BlockTransfer.Supervisor, {__MODULE__, args}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @spec cache_completion(pid(), binary() | nil) :: :ok
  def cache_completion(pid, reply_bin) when is_pid(pid) do
    GenServer.call(pid, {:cache_completion, reply_bin})
  end

  @spec cache_completion(pid(), :inet.ip_address(), binary(), binary() | nil) :: :ok
  def cache_completion(endpoint, ip, token, reply_bin) when is_pid(endpoint) do
    case Registry.whereis(endpoint, {:block_transfer, ip, token}) do
      nil -> :ok
      pid -> cache_completion(pid, reply_bin)
    end
  end

  @impl true
  def init(%{ip: ip, token: token, handler: handler}) do
    state = %__MODULE__{
      ip: ip,
      token: token,
      handler: handler,
      blocks: Blocks.empty(),
      last_reply: nil,
      phase: :assembling
    }

    Logger.info("[BlockTransfer] started", peer: peer_id(state))
    {:ok, state, @assembling_timeout}
  end

  @impl true
  def handle_call(
        {:block, %Message{descriptive_block: %Block{} = b} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      )
      when b.more == true do
    blocks = Blocks.push(state.blocks, message)

    Logger.info("[BlockTransfer] block accepted",
      peer: peer_id(state),
      block: b.number,
      size: byte_size(message.payload),
      more: true
    )

    {:ok, ack_bin} = message |> Message.response(code: :continue, type: :ack) |> encode_reply()

    {:reply, {:continue, ack_bin}, %{state | blocks: blocks}, @assembling_timeout}
  end

  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: false} = b} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    blocks = Blocks.push(state.blocks, message)

    Logger.info("[BlockTransfer] block accepted",
      peer: peer_id(state),
      block: b.number,
      size: byte_size(message.payload),
      more: false
    )

    case Blocks.read(blocks) do
      {:ok, payload} ->
        Logger.info("[BlockTransfer] blocks assembled",
          peer: peer_id(state),
          count: map_size(blocks),
          total_size: byte_size(payload)
        )

        full = %Message{message | payload: payload}
        {:reply, {:assembled, full}, %{state | blocks: blocks}, @assembling_timeout}

      {:error, {:missing, n}} ->
        Logger.info("[BlockTransfer] blocks incomplete",
          peer: peer_id(state),
          missing: n,
          have: map_size(blocks)
        )

        {:ok, bin} =
          message
          |> Message.response(code: :request_entity_incomplete, type: :ack)
          |> encode_reply()

        {:reply, {:incomplete, bin}, %{state | blocks: blocks}, @assembling_timeout}
    end
  end

  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: false}}},
        _from,
        %__MODULE__{phase: :complete, last_reply: reply_bin} = state
      ) do
    Logger.info("[BlockTransfer] duplicate final block, replaying cached reply",
      peer: peer_id(state),
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
      reply_size: reply_size
    )

    {:reply, :ok, %{state | last_reply: reply_bin, phase: :complete}, @complete_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("[BlockTransfer] timeout, shutting down",
      peer: peer_id(state),
      phase: state.phase
    )

    {:stop, :normal, state}
  end

  defp encode_reply({:ok, %Message{} = reply}), do: Message.encode(reply)
  defp encode_reply({:error, _} = err), do: err

  defp peer_id(%__MODULE__{ip: ip, token: token}) do
    "#{:inet.ntoa(ip)}/#{Base.encode16(token, case: :lower)}"
  end
end
