defmodule Macrina.Observe do
  @moduledoc false

  # Server-side observe registry (RFC 7641). VM-wide singleton GenServer with
  # three synchronized indexes (subscriptions, paths, connections). Wrapped by
  # `Macrina.Server.notify/3` and `Macrina.Client.observe/3`. Planned for
  # per-endpoint decomposition in Wave C.

  use GenServer

  alias Macrina.{Discovery.Resource, Telemetry}

  # Server-side observe registry.
  #
  # Tracks observe relationships across all endpoints and connections, indexed
  # three ways for efficient lookup:
  #
  #   subscriptions  — canonical store, keyed by {endpoint, connection, token}
  #   paths          — reverse index from {endpoint, path} to subscription keys
  #   connections    — reverse index from connection pid to subscription keys
  #
  # Sequence numbers are managed here so that `notifications/2` can atomically
  # increment and return the next observe value for each active subscriber.

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

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Registers an observe subscription. Returns `{:ok, sequence}` or `{:error, reason}`."
  def register(endpoint, connection, path, token)
      when is_pid(endpoint) and is_pid(connection) and is_binary(token) do
    GenServer.call(__MODULE__, {:register, endpoint, connection, path, token})
  end

  @doc "Cancels an observe subscription identified by endpoint, connection, and token."
  def cancel(endpoint, connection, token)
      when is_pid(endpoint) and is_pid(connection) and is_binary(token) do
    GenServer.call(__MODULE__, {:cancel, endpoint, connection, token})
  end

  @doc """
  Returns `{:ok, notifications}` for all active observers on `path`.

  Each notification map includes the next sequence number as `:observe`.
  Dead connections are evicted automatically.
  """
  def notifications(endpoint, path) when is_pid(endpoint) do
    GenServer.call(__MODULE__, {:notifications, endpoint, path})
  end

  @doc "Removes all subscriptions associated with the given connection pid."
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
      state_without_existing = remove_subscription(state, key)

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
        |> add_to_path_index(key, endpoint, normalized_path)
        |> add_to_connection_index(key, connection)

      emit_telemetry(:register, subscription)

      {:reply, {:ok, 0}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:cancel, endpoint, connection, token}, _from, %__MODULE__{} = state) do
    key = {endpoint, connection, token}
    {subscription, next_state} = pop_subscription(state, key)

    if subscription, do: emit_telemetry(:cancel, subscription)

    {:reply, :ok, next_state}
  end

  @impl true
  def handle_call({:notifications, endpoint, path}, _from, %__MODULE__{} = state) do
    with {:ok, normalized_path} <- normalize_path(path) do
      {notifications, next_state} = collect_notifications(state, endpoint, normalized_path)
      {:reply, {:ok, notifications}, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:drop_connection, connection}, _from, %__MODULE__{} = state) do
    keys = Map.get(state.connections, connection, MapSet.new())

    next_state =
      Enum.reduce(keys, state, fn key, acc ->
        {_subscription, next} = pop_subscription(acc, key)
        next
      end)

    {:reply, :ok, next_state}
  end

  # --- notification collection ---

  defp collect_notifications(%__MODULE__{} = state, endpoint, path) do
    keys = Map.get(state.paths, {endpoint, path}, MapSet.new())

    {notifications, next_state} =
      Enum.reduce(keys, {[], state}, fn key, {acc, acc_state} ->
        case Map.fetch(acc_state.subscriptions, key) do
          {:ok, %{connection: connection} = subscription} ->
            if Process.alive?(connection) do
              next_sequence = subscription.sequence + 1
              next_subscription = %{subscription | sequence: next_sequence}
              updated_state = put_subscription(acc_state, key, next_subscription)
              notification = Map.put(next_subscription, :observe, next_sequence)

              {[notification | acc], updated_state}
            else
              {evicted, updated_state} = pop_subscription(acc_state, key)
              if evicted, do: emit_telemetry(:cancel, evicted)
              {acc, updated_state}
            end

          :error ->
            {acc, acc_state}
        end
      end)

    {Enum.reverse(notifications), next_state}
  end

  # --- subscription CRUD ---

  defp put_subscription(%__MODULE__{} = state, key, subscription) do
    %__MODULE__{state | subscriptions: Map.put(state.subscriptions, key, subscription)}
  end

  defp remove_subscription(%__MODULE__{} = state, key) do
    {_subscription, next_state} = pop_subscription(state, key)
    next_state
  end

  defp pop_subscription(%__MODULE__{} = state, key) do
    case Map.pop(state.subscriptions, key) do
      {nil, _} ->
        {nil, state}

      {%{connection: connection, endpoint: endpoint, path: path} = subscription,
       remaining_subscriptions} ->
        next_state =
          %__MODULE__{state | subscriptions: remaining_subscriptions}
          |> remove_from_path_index(key, endpoint, path)
          |> remove_from_connection_index(key, connection)

        {subscription, next_state}
    end
  end

  # --- index management ---
  #
  # Each index maps a lookup key to a MapSet of subscription keys.
  # When the last key is removed the entry is cleaned up entirely.

  defp add_to_path_index(%__MODULE__{paths: paths} = state, key, endpoint, path) do
    index_key = {endpoint, path}
    next_paths = Map.update(paths, index_key, MapSet.new([key]), &MapSet.put(&1, key))
    %__MODULE__{state | paths: next_paths}
  end

  defp add_to_connection_index(%__MODULE__{connections: connections} = state, key, connection) do
    next_connections =
      Map.update(connections, connection, MapSet.new([key]), &MapSet.put(&1, key))

    %__MODULE__{state | connections: next_connections}
  end

  defp remove_from_path_index(%__MODULE__{paths: paths} = state, key, endpoint, path) do
    index_key = {endpoint, path}
    %__MODULE__{state | paths: delete_from_index(paths, index_key, key)}
  end

  defp remove_from_connection_index(
         %__MODULE__{connections: connections} = state,
         key,
         connection
       ) do
    %__MODULE__{state | connections: delete_from_index(connections, connection, key)}
  end

  defp delete_from_index(index, index_key, member_key) do
    case Map.fetch(index, index_key) do
      {:ok, members} ->
        remaining = MapSet.delete(members, member_key)

        if MapSet.size(remaining) == 0 do
          Map.delete(index, index_key)
        else
          Map.put(index, index_key, remaining)
        end

      :error ->
        index
    end
  end

  defp normalize_path(path) do
    case Resource.new(path, []) do
      {:ok, %Resource{path: normalized_path}} -> {:ok, normalized_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_telemetry(event, subscription) do
    Telemetry.execute([:observe, event], %{count: 1}, %{
      path: subscription.path,
      token: subscription.token
    })
  end
end
