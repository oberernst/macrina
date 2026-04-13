defmodule Macrina.Observe do
  use GenServer

  alias Macrina.{Discovery.Resource, Telemetry}

  defstruct connections: %{}, paths: %{}, subscriptions: %{}

  @type path :: [String.t()]
  @type server_subscription :: %{
          connection: pid(),
          endpoint: pid(),
          path: path(),
          sequence: non_neg_integer(),
          token: binary()
        }
  @type t :: %__MODULE__{
          connections: %{optional(pid()) => MapSet.t(subscription_key())},
          paths: %{optional({pid(), path()}) => MapSet.t(subscription_key())},
          subscriptions: %{optional(subscription_key()) => server_subscription()}
        }
  @type subscription_key :: {pid(), pid(), binary()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  def register(endpoint, connection, path, token)
      when is_pid(endpoint) and is_pid(connection) and is_binary(token) do
    GenServer.call(__MODULE__, {:register, endpoint, connection, path, token})
  end

  def cancel(endpoint, connection, token)
      when is_pid(endpoint) and is_pid(connection) and is_binary(token) do
    GenServer.call(__MODULE__, {:cancel, endpoint, connection, token})
  end

  def notifications(endpoint, path) when is_pid(endpoint) do
    GenServer.call(__MODULE__, {:notifications, endpoint, path})
  end

  def drop_connection(connection) when is_pid(connection) do
    GenServer.call(__MODULE__, {:drop_connection, connection})
  end

  @impl true
  def init(%__MODULE__{} = state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:register, endpoint, connection, path, token}, _from, %__MODULE__{} = state) do
    with {:ok, normalized_path} <- normalize_path(path) do
      key = {endpoint, connection, token}
      state_without_existing = delete_subscription(state, key)

      subscription = %{
        connection: connection,
        endpoint: endpoint,
        path: normalized_path,
        sequence: 0,
        token: token
      }

      next_state =
        state_without_existing
        |> put_subscription(key, subscription)
        |> index_path(key, endpoint, normalized_path)
        |> index_connection(key, connection)

      emit_register(subscription)

      {:reply, {:ok, 0}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, endpoint, connection, token}, _from, %__MODULE__{} = state) do
    key = {endpoint, connection, token}
    {subscription, next_state} = delete_subscription_with_result(state, key)

    if subscription do
      emit_cancel(subscription)
    end

    {:reply, :ok, next_state}
  end

  def handle_call({:notifications, endpoint, path}, _from, %__MODULE__{} = state) do
    with {:ok, normalized_path} <- normalize_path(path) do
      {notifications, next_state} = next_notifications(state, endpoint, normalized_path)
      {:reply, {:ok, notifications}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:drop_connection, connection}, _from, %__MODULE__{} = state) do
    next_state = drop_connection_subscriptions(state, connection)
    {:reply, :ok, next_state}
  end

  defp next_notifications(%__MODULE__{} = state, endpoint, path) do
    keys = Map.get(state.paths, {endpoint, path}, MapSet.new())

    Enum.reduce(keys, {[], state}, fn key, {notifications, acc_state} ->
      case Map.fetch(acc_state.subscriptions, key) do
        {:ok, %{connection: connection} = subscription} ->
          if Process.alive?(connection) do
            next_sequence = subscription.sequence + 1
            next_subscription = %{subscription | sequence: next_sequence}
            next_state = put_subscription(acc_state, key, next_subscription)

            notification = Map.put(next_subscription, :observe, next_sequence)

            {[notification | notifications], next_state}
          else
            {subscription, next_state} = delete_subscription_with_result(acc_state, key)

            if subscription do
              emit_cancel(subscription)
            end

            {notifications, next_state}
          end

        :error ->
          {notifications, acc_state}
      end
    end)
    |> then(fn {notifications, next_state} -> {Enum.reverse(notifications), next_state} end)
  end

  defp drop_connection_subscriptions(%__MODULE__{} = state, connection) do
    state.connections
    |> Map.get(connection, MapSet.new())
    |> Enum.reduce(state, fn key, acc_state ->
      {_subscription, next_state} = delete_subscription_with_result(acc_state, key)
      next_state
    end)
  end

  defp put_subscription(%__MODULE__{subscriptions: subscriptions} = state, key, subscription) do
    next_subscriptions = Map.put(subscriptions, key, subscription)
    %__MODULE__{state | subscriptions: next_subscriptions}
  end

  defp index_path(%__MODULE__{paths: paths} = state, key, endpoint, path) do
    path_key = {endpoint, path}
    next_keys = Map.get(paths, path_key, MapSet.new()) |> MapSet.put(key)
    next_paths = Map.put(paths, path_key, next_keys)

    %__MODULE__{state | paths: next_paths}
  end

  defp index_connection(%__MODULE__{connections: connections} = state, key, connection) do
    next_keys = Map.get(connections, connection, MapSet.new()) |> MapSet.put(key)
    next_connections = Map.put(connections, connection, next_keys)

    %__MODULE__{state | connections: next_connections}
  end

  defp delete_subscription(%__MODULE__{} = state, key) do
    {_subscription, next_state} = delete_subscription_with_result(state, key)
    next_state
  end

  defp delete_subscription_with_result(%__MODULE__{} = state, key) do
    case Map.pop(state.subscriptions, key) do
      {nil, _subscriptions} ->
        {nil, state}

      {%{connection: connection, endpoint: endpoint, path: path} = subscription,
       next_subscriptions} ->
        next_state =
          state
          |> put_deleted_subscriptions(next_subscriptions)
          |> drop_path_index(key, endpoint, path)
          |> drop_connection_index(key, connection)

        {subscription, next_state}
    end
  end

  defp put_deleted_subscriptions(%__MODULE__{} = state, next_subscriptions) do
    %__MODULE__{state | subscriptions: next_subscriptions}
  end

  defp drop_path_index(%__MODULE__{paths: paths} = state, key, endpoint, path) do
    path_key = {endpoint, path}
    next_keys = Map.get(paths, path_key, MapSet.new()) |> MapSet.delete(key)

    next_paths =
      if MapSet.size(next_keys) == 0 do
        Map.delete(paths, path_key)
      else
        Map.put(paths, path_key, next_keys)
      end

    %__MODULE__{state | paths: next_paths}
  end

  defp drop_connection_index(%__MODULE__{connections: connections} = state, key, connection) do
    next_keys = Map.get(connections, connection, MapSet.new()) |> MapSet.delete(key)

    next_connections =
      if MapSet.size(next_keys) == 0 do
        Map.delete(connections, connection)
      else
        Map.put(connections, connection, next_keys)
      end

    %__MODULE__{state | connections: next_connections}
  end

  defp normalize_path(path) do
    case Resource.new(path, []) do
      {:ok, %Resource{path: normalized_path}} -> {:ok, normalized_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_register(subscription) do
    Telemetry.execute([:observe, :register], %{count: 1}, %{
      path: subscription.path,
      token: subscription.token
    })
  end

  defp emit_cancel(subscription) do
    Telemetry.execute([:observe, :cancel], %{count: 1}, %{
      path: subscription.path,
      token: subscription.token
    })
  end
end
