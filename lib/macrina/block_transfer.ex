defmodule Macrina.BlockTransfer do
  @moduledoc false

  use GenServer, restart: :transient

  alias Macrina.{Blocks, Message}
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
    ip = Keyword.fetch!(args, :ip)
    token = Keyword.fetch!(args, :token)
    handler = Keyword.fetch!(args, :handler)
    name = Keyword.get(args, :name)
    init_arg = %{ip: ip, token: token, handler: handler}

    case name do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  @spec handle_block(pid(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(pid, %Message{} = message) do
    GenServer.call(pid, {:block, message})
  end

  @spec handle_block(:inet.ip_address(), binary(), module(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
          | {:duplicate, binary() | nil}
  def handle_block(ip, token, handler, %Message{} = message) do
    ip
    |> lookup_or_start(token, handler)
    |> handle_block(message)
  end

  defp lookup_or_start(ip, token, handler) do
    case :global.whereis_name({__MODULE__, ip, token}) do
      pid when is_pid(pid) ->
        pid

      :undefined ->
        spec = %{
          id: __MODULE__,
          start:
            {__MODULE__, :start_link,
             [
               [
                 ip: ip,
                 token: token,
                 handler: handler,
                 name: {:global, {__MODULE__, ip, token}}
               ]
             ]},
          restart: :transient,
          type: :worker
        }

        case DynamicSupervisor.start_child(Macrina.BlockTransfer.Supervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @doc false
  @spec cache_completion(pid(), binary() | nil) :: :ok
  def cache_completion(pid, reply_bin)
      when is_pid(pid) and (is_binary(reply_bin) or is_nil(reply_bin)) do
    GenServer.call(pid, {:cache_completion, reply_bin})
  end

  @spec cache_completion(:inet.ip_address(), binary(), binary() | nil) :: :ok
  def cache_completion(ip, token, reply_bin)
      when is_binary(reply_bin) or is_nil(reply_bin) do
    case :global.whereis_name({__MODULE__, ip, token}) do
      :undefined -> :ok
      pid -> GenServer.call(pid, {:cache_completion, reply_bin})
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

    {:ok, state, @assembling_timeout}
  end

  @impl true
  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: true}} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    blocks = Blocks.push(state.blocks, message)
    ack_bin = message |> Message.response(code: :continue, type: :ack) |> Message.encode()
    {:reply, {:continue, ack_bin}, %{state | blocks: blocks}, @assembling_timeout}
  end

  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: false}} = message},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    blocks = Blocks.push(state.blocks, message)

    case Blocks.read(blocks) do
      {:ok, payload} ->
        full = %Message{message | payload: payload}
        {:reply, {:assembled, full}, %{state | blocks: blocks}, @assembling_timeout}

      {:error, {:missing, _n}} ->
        bin =
          message
          |> Message.response(code: :request_entity_incomplete, type: :ack)
          |> Message.encode()

        {:reply, {:incomplete, bin}, %{state | blocks: blocks}, @assembling_timeout}
    end
  end

  def handle_call(
        {:block, %Message{descriptive_block: %Block{more: false}}},
        _from,
        %__MODULE__{phase: :complete, last_reply: reply_bin} = state
      ) do
    {:reply, {:duplicate, reply_bin}, state, @complete_timeout}
  end

  def handle_call(
        {:cache_completion, reply_bin},
        _from,
        %__MODULE__{phase: :assembling} = state
      ) do
    {:reply, :ok, %{state | last_reply: reply_bin, phase: :complete}, @complete_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end
end
