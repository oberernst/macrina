defmodule Macrina.Connection do
  alias Macrina.{Exchange, Handler, Message}

  defstruct ack_timeout: 2_000,
            block1_max_body_size: :infinity,
            block1_mode: :atomic,
            block1_preferred_block_size: nil,
            endpoint: nil,
            exchange: %Exchange{},
            exchange_lifetime: 247_000,
            handler: nil,
            ip: nil,
            max_retransmit: 4,
            name: nil,
            observe_subscriptions: %{},
            port: nil,
            retry_timers: %{},
            socket: nil

  @type t :: %__MODULE__{
          ack_timeout: non_neg_integer(),
          block1_max_body_size: non_neg_integer() | :infinity,
          block1_mode: :atomic | :streaming,
          block1_preferred_block_size: pos_integer() | nil,
          endpoint: pid() | nil,
          exchange: Exchange.t(),
          exchange_lifetime: non_neg_integer(),
          handler: Handler.t(),
          ip: tuple(),
          max_retransmit: non_neg_integer(),
          name: String.t(),
          observe_subscriptions: %{optional(binary()) => map()},
          port: integer(),
          retry_timers: %{optional(binary()) => reference()},
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

  def store_block(%__MODULE__{exchange: exchange} = state, %Message{} = message) do
    case Exchange.store_block(exchange, message) do
      {:ok, next_exchange} -> {:ok, put_exchange(state, next_exchange)}
      {:error, reason} -> {:error, reason}
    end
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

  def track_request(%__MODULE__{} = state, %Message{} = message, from, packet)
      when is_binary(packet) do
    max_retransmit = state.max_retransmit

    update_exchange(state, &Exchange.track_request(&1, message, from, packet, max_retransmit))
  end

  @spec read_blocks(t(), Message.t()) :: String.t() | nil
  def read_blocks(%__MODULE__{exchange: exchange}, %Message{} = message) do
    Exchange.read_blocks(exchange, message)
  end

  @spec block_transfer(t(), Message.t()) :: {:ok, map()} | :error
  def block_transfer(%__MODULE__{exchange: exchange}, %Message{} = message) do
    Exchange.block_transfer(exchange, message)
  end

  @spec reply(t(), binary()) :: :ok | {:error, term()}
  def reply(%__MODULE__{ip: ip, port: port, socket: socket}, bin) when is_binary(bin) do
    :gen_udp.send(socket, {ip, port}, bin)
  end

  def reset_blocks(%__MODULE__{} = state) do
    update_exchange(state, &Exchange.reset_blocks/1)
  end

  def reset_blocks(%__MODULE__{} = state, %Message{} = message) do
    update_exchange(state, &Exchange.reset_blocks(&1, message))
  end

  @spec cache_reply(t(), Message.t(), binary() | nil) :: t()
  def cache_reply(%__MODULE__{} = state, %Message{} = message, reply) do
    update_exchange(state, &Exchange.cache_reply(&1, message, reply))
  end

  @spec cached_reply(t(), Message.t()) :: {:ok, binary() | nil} | :error
  def cached_reply(
        %__MODULE__{exchange: exchange, exchange_lifetime: exchange_lifetime},
        %Message{} = message
      ) do
    now = System.monotonic_time(:millisecond)
    Exchange.cached_reply(exchange, message, now, exchange_lifetime)
  end

  @spec pending_request(t(), binary()) :: {:ok, Exchange.pending_request()} | :error
  def pending_request(%__MODULE__{exchange: exchange}, token) when is_binary(token) do
    Exchange.pending_request(exchange, token)
  end

  @spec pending_request_for_id(t(), non_neg_integer()) ::
          {:ok, {binary(), Exchange.pending_request()}} | :error
  def pending_request_for_id(%__MODULE__{exchange: exchange}, id) when is_integer(id) do
    Exchange.pending_request_for_id(exchange, id)
  end

  @spec acknowledge_request(t(), Message.t()) :: {Exchange.pending_request() | nil, t()}
  def acknowledge_request(%__MODULE__{} = state, %Message{} = message) do
    {request, next_exchange} = Exchange.acknowledge_request(state.exchange, message)
    {request, put_exchange(state, next_exchange)}
  end

  @spec retry_request(t(), binary()) ::
          {{:retransmit, Exchange.pending_request()}
           | {:timeout, Exchange.pending_request()}
           | :ignore, t()}
  def retry_request(%__MODULE__{} = state, token) when is_binary(token) do
    {action, next_exchange} = Exchange.retry_request(state.exchange, token)
    {action, put_exchange(state, next_exchange)}
  end

  @spec complete_pending_request(t(), binary()) :: {Exchange.pending_request() | nil, t()}
  def complete_pending_request(%__MODULE__{} = state, token) when is_binary(token) do
    {request, next_exchange} = Exchange.complete_pending_request(state.exchange, token)
    {request, put_exchange(state, next_exchange)}
  end

  def put_retry_timer(%__MODULE__{retry_timers: retry_timers} = state, token, timer_ref)
      when is_binary(token) do
    next_timers = Map.put(retry_timers, token, timer_ref)
    %__MODULE__{state | retry_timers: next_timers}
  end

  def pop_retry_timer(%__MODULE__{retry_timers: retry_timers} = state, token)
      when is_binary(token) do
    {timer_ref, next_timers} = Map.pop(retry_timers, token)
    {timer_ref, %__MODULE__{state | retry_timers: next_timers}}
  end

  defp update_exchange(%__MODULE__{exchange: exchange} = state, fun) do
    next_exchange = fun.(exchange)
    put_exchange(state, next_exchange)
  end

  defp put_exchange(%__MODULE__{} = state, %Exchange{} = exchange) do
    %__MODULE__{state | exchange: exchange}
  end
end
