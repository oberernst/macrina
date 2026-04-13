defmodule Macrina.Connection do
  alias Macrina.{Exchange, Handler, Message}

  defstruct [:exchange, :handler, :ip, :name, :port, :socket]

  @type t :: %__MODULE__{
          exchange: Exchange.t(),
          handler: Handler.t(),
          ip: tuple(),
          name: String.t(),
          port: integer(),
          socket: port()
        }

  def complete_request(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.complete_request(&1, message))
  end

  def pop_caller(%__MODULE__{} = state, caller) do
    update_exchange(state, &Exchange.pop_caller(&1, caller))
  end

  def pop_caller_for_token(%__MODULE__{exchange: exchange} = state, token) do
    {caller, next_exchange} = Exchange.pop_caller_for_token(exchange, token)
    {caller, put_exchange(state, next_exchange)}
  end

  def pop_id(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.pop_id(&1, message))
  end

  def pop_token(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.pop_token(&1, message))
  end

  def push_block(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.push_block(&1, message))
  end

  def push_caller(%__MODULE__{} = state, caller) do
    update_exchange(state, &Exchange.push_caller(&1, caller))
  end

  def push_id(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.push_id(&1, message))
  end

  def push_token(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.push_token(&1, message))
  end

  def register_request(%__MODULE__{} = state, %Message{} = message, from) do
    update_exchange(state, &Exchange.register_request(&1, message, from))
  end

  @spec read_blocks(t()) :: String.t() | nil
  def read_blocks(%__MODULE__{exchange: exchange}) do
    Exchange.read_blocks(exchange)
  end

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end

  def reset_blocks(%__MODULE__{} = state) do
    update_exchange(state, &Exchange.reset_blocks/1)
  end

  @spec set_last_reply(t(), binary(), binary() | nil) :: t()
  def set_last_reply(%__MODULE__{} = state, token, reply) do
    update_exchange(state, &Exchange.set_last_reply(&1, token, reply))
  end

  def last_reply(%__MODULE__{exchange: exchange}) do
    Exchange.last_reply(exchange)
  end

  defp update_exchange(%__MODULE__{exchange: exchange} = state, fun) do
    next_exchange = fun.(exchange)
    put_exchange(state, next_exchange)
  end

  defp put_exchange(%__MODULE__{} = state, %Exchange{} = exchange) do
    %__MODULE__{state | exchange: exchange}
  end
end
