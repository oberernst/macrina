defmodule Macrina.Connection do
  alias Macrina.{Message, Message.Opts.Block}
  require Logger

  defstruct [:blocks, :callers, :last_reply, :handler, :ids, :ip, :name, :port, :socket, :tokens]

  @type t :: %__MODULE__{
          blocks: %{},
          callers: [{binary(), tuple()}],
          last_reply: {binary(), binary()},
          handler: module(),
          ip: tuple(),
          name: String.t(),
          port: integer(),
          socket: port()
        }

  def pop_caller(%__MODULE__{callers: callers} = state, caller) do
    %__MODULE__{state | callers: List.delete(callers, caller)}
  end

  def pop_id(%__MODULE__{ids: ids} = state, %Message{id: id}) do
    %__MODULE__{state | ids: List.delete(ids, id)}
  end

  def pop_token(%__MODULE__{tokens: tokens} = state, %Message{token: token}) do
    %__MODULE__{state | ids: List.delete(tokens, token)}
  end

  def push_block(%__MODULE__{blocks: blocks} = state, %Message{
        descriptive_block: %Block{number: num},
        payload: payload
      }) do
    blocks = Map.put(blocks, num, payload)
    Logger.info("#{__MODULE__}.push_block/2 adding block #{num}", blocks: blocks)
    %__MODULE__{state | blocks: blocks}
  end

  def push_caller(%__MODULE__{callers: callers} = state, caller) do
    %__MODULE__{state | callers: [caller | callers]}
  end

  def push_id(%__MODULE__{ids: ids} = state, %Message{id: id}) do
    %__MODULE__{state | ids: [id | ids]}
  end

  def push_token(%__MODULE__{tokens: tokens} = state, %Message{token: token}) do
    %__MODULE__{state | tokens: [token | tokens]}
  end

  @spec read_blocks(t()) :: String.t() | nil
  def read_blocks(%__MODULE__{blocks: blocks} = state) do
    sorted = Enum.sort_by(blocks, &elem(&1, 0), :asc)

    {missing, valid?} =
      Enum.reduce_while(sorted, {-1, true}, fn {num, _}, {last_num, _} ->
        if last_num + 1 == num do
          {:cont, {num, true}}
        else
          {:halt, {num - 1, false}}
        end
      end)

    if valid? do
      payload = Enum.reduce(sorted, "", fn {_, str}, acc -> acc <> str end)
      Logger.info("#{__MODULE__}.read_blocks/1", payload: payload)
      payload
    else
      Logger.warn("#{__MODULE__}.read_blocks/1 missing at least block #{missing}", state: state)
      nil
    end
  end

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end

  def reset_blocks(%__MODULE__{} = state), do: %__MODULE__{state | blocks: %{}}

  @spec set_last_reply(t(), binary(), binary() | nil) :: t()
  def set_last_reply(%__MODULE__{} = state, token, reply) do
    %__MODULE__{state | last_reply: {token, reply}}
  end
end
