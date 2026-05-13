defmodule Macrina.BlockTransfer do
  @moduledoc false

  use GenServer, restart: :transient

  alias Macrina.{Blocks, Message}
  alias Macrina.Message.Opts.Block

  @assembling_timeout :timer.minutes(5)

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
    GenServer.start_link(__MODULE__, %{ip: ip, token: token, handler: handler})
  end

  @spec handle_block(pid(), Message.t()) ::
          {:continue, binary()}
          | {:assembled, Message.t()}
          | {:incomplete, binary()}
  def handle_block(pid, %Message{} = message) do
    GenServer.call(pid, {:block, message})
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

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end
end
