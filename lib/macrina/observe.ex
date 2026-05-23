defmodule Macrina.Observe do
  @moduledoc false

  # Server-side observe registry (RFC 7641). State lives in
  # `Macrina.Observe.Registry`, a `:duplicate`-keys `Registry` keyed by
  # `{endpoint_pid, path}`. Subscribers self-register from the
  # `Macrina.Peer.Session` process, so Registry's pid monitor evicts a
  # subscription automatically when its session dies — no central
  # GenServer, no drop-connection book-keeping.

  alias Macrina.{Discovery.Resource, Telemetry}

  @type path :: [String.t()]
  @type subscription_value :: %{
          token: binary(),
          path: path(),
          seq_ref: :atomics.atomics_ref()
        }
  @type notification :: %{
          connection: pid(),
          endpoint: pid(),
          path: path(),
          sequence: pos_integer(),
          token: binary(),
          observe: pos_integer()
        }

  @doc """
  Subscribes the calling process to `endpoint`/`path` under `token`.

  Returns `{:ok, 0}` for the initial sequence number, or `{:error, reason}`
  if the path is not a valid CoAP resource path. Must be called from the
  process that owns the subscription — typically a `Macrina.Peer.Session`
  — so the Registry's pid monitor can evict the entry when the owner
  exits.
  """
  @spec subscribe(pid(), String.t() | path(), binary()) ::
          {:ok, 0} | {:error, term()}
  def subscribe(endpoint, path, token) when is_pid(endpoint) and is_binary(token) do
    with {:ok, normalized_path} <- normalize_path(path) do
      value = %{
        token: token,
        path: normalized_path,
        seq_ref: new_sequence_ref()
      }

      case Registry.register(__MODULE__.Registry, {endpoint, normalized_path}, value) do
        {:ok, _owner} ->
          emit_telemetry(:register, normalized_path, token)
          {:ok, 0}

        {:error, {:already_registered, _pid}} ->
          {:ok, 0}
      end
    end
  end

  @doc """
  Cancels the calling process's subscription on `endpoint`/`path` that
  matches `token`. Other subscriptions held by the same process — on
  other paths or under other tokens — are untouched. Must be called
  from the same process that called `subscribe/3`.
  """
  @spec cancel(pid(), String.t() | path(), binary()) :: :ok | {:error, term()}
  def cancel(endpoint, path, token) when is_pid(endpoint) and is_binary(token) do
    with {:ok, normalized_path} <- normalize_path(path) do
      Registry.unregister_match(
        __MODULE__.Registry,
        {endpoint, normalized_path},
        %{token: token}
      )

      emit_telemetry(:cancel, normalized_path, token)
      :ok
    end
  end

  @doc """
  Returns `{:ok, notifications}` for every active subscriber on
  `endpoint`/`path`. Each notification's `:observe` and `:sequence` are
  the next value from that subscription's `:atomics` counter.
  """
  @spec notifications(pid(), String.t() | path()) ::
          {:ok, [notification()]} | {:error, term()}
  def notifications(endpoint, path) when is_pid(endpoint) do
    with {:ok, normalized_path} <- normalize_path(path) do
      notifications =
        __MODULE__.Registry
        |> Registry.lookup({endpoint, normalized_path})
        |> Enum.map(fn {connection, %{token: token, seq_ref: ref, path: p}} ->
          next = :atomics.add_get(ref, 1, 1)

          %{
            connection: connection,
            endpoint: endpoint,
            path: p,
            sequence: next,
            token: token,
            observe: next
          }
        end)

      {:ok, notifications}
    end
  end

  defp new_sequence_ref do
    :atomics.new(1, signed: false)
  end

  defp normalize_path(path) do
    case Resource.new(path, []) do
      {:ok, %Resource{path: normalized_path}} -> {:ok, normalized_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_telemetry(event, path, token) do
    Telemetry.execute([:observe, event], %{count: 1}, %{path: path, token: token})
  end
end
