defmodule Macrina.Connection do
  alias Macrina.{Exchange, Handler, Message}

  defstruct [:callers, :exchange, :handler, :ip, :name, :port, :socket]

  @type t :: %__MODULE__{
          callers: [{binary(), tuple()}],
          exchange: Exchange.t(),
          handler: Handler.t(),
          ip: tuple(),
          name: String.t(),
          port: integer(),
          socket: port()
        }

  def pop_caller(%__MODULE__{callers: callers} = state, caller) do
    %__MODULE__{state | callers: List.delete(callers, caller)}
  end

  def pop_id(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    next_exchange = Exchange.pop_id(exchange, message)
    put_exchange(state, next_exchange)
  end

  def pop_token(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    next_exchange = Exchange.pop_token(exchange, message)
    put_exchange(state, next_exchange)
  end

  def push_block(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    next_exchange = Exchange.push_block(exchange, message)
    put_exchange(state, next_exchange)
  end

  def push_caller(%__MODULE__{callers: callers} = state, caller) do
    %__MODULE__{state | callers: [caller | callers]}
  end

  def push_id(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    next_exchange = Exchange.push_id(exchange, message)
    put_exchange(state, next_exchange)
  end

  def push_token(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    next_exchange = Exchange.push_token(exchange, message)
    put_exchange(state, next_exchange)
  end

  @spec read_blocks(t()) :: String.t() | nil
  def read_blocks(%__MODULE__{exchange: exchange}) do
    Exchange.read_blocks(exchange)
  end

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end

  def reset_blocks(%__MODULE__{exchange: exchange} = state) do
    next_exchange = Exchange.reset_blocks(exchange)
    put_exchange(state, next_exchange)
  end

  @spec set_last_reply(t(), binary(), binary() | nil) :: t()
  def set_last_reply(%__MODULE__{exchange: exchange} = state, token, reply) do
    next_exchange = Exchange.set_last_reply(exchange, token, reply)
    put_exchange(state, next_exchange)
  end

  def last_reply(%__MODULE__{exchange: exchange}) do
    Exchange.last_reply(exchange)
  end

  defp put_exchange(%__MODULE__{} = state, %Exchange{} = exchange) do
    %__MODULE__{state | exchange: exchange}
  end
end
