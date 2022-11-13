defmodule Macrina.Connection do
  alias Macrina.Message
  require Logger

  defstruct [:callers, :handler, :ids, :ip, :name, :port, :seen_ids, :socket, :tokens]

  @type t :: %__MODULE__{
          callers: [{binary(), tuple()}],
          handler: module(),
          ip: tuple(),
          name: String.t(),
          port: integer(),
          seen_ids: [integer()],
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

  def push_caller(%__MODULE__{callers: callers} = state, caller) do
    %__MODULE__{state | callers: [caller | callers]}
  end

  def push_id(%__MODULE__{ids: ids} = state, %Message{id: id}) do
    %__MODULE__{state | ids: [id | ids]}
  end

  def push_seen_id(%__MODULE__{seen_ids: seen_ids} = state, %Message{id: id}) do
    %__MODULE__{state | seen_ids: [id | seen_ids]}
  end

  def push_token(%__MODULE__{tokens: tokens} = state, %Message{token: token}) do
    %__MODULE__{state | tokens: [token | tokens]}
  end

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end
end
