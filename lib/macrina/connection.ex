defmodule Macrina.Connection do
  alias Macrina.Message

  defstruct [:callers, :last_reply, :handler, :ids, :ip, :name, :port, :socket, :tokens]

  @type t :: %__MODULE__{
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
    %__MODULE__{state | tokens: List.delete(tokens, token)}
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

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end

  @spec set_last_reply(t(), binary(), binary() | nil) :: t()
  def set_last_reply(%__MODULE__{} = state, token, reply) do
    %__MODULE__{state | last_reply: {token, reply}}
  end
end
