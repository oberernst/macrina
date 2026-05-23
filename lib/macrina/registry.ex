defmodule Macrina.Registry do
  @moduledoc false

  @type endpoint :: term()
  @type role :: term()
  @type key :: endpoint() | {endpoint(), role()}
  @type value :: term()

  def child_spec(_arg) do
    [keys: :unique, name: __MODULE__]
    |> Registry.child_spec()
    |> Supervisor.child_spec(id: __MODULE__)
  end

  @spec via(endpoint(), role() | nil, value()) :: {:via, Registry, tuple()}
  def via(endpoint, role \\ nil, value \\ nil)
  def via(endpoint, role, nil), do: {:via, Registry, {__MODULE__, key(endpoint, role)}}
  def via(endpoint, role, value), do: {:via, Registry, {__MODULE__, key(endpoint, role), value}}

  @spec whereis(endpoint(), role()) :: pid() | {atom(), node()} | nil
  def whereis(endpoint, role \\ nil) do
    endpoint
    |> via(role)
    |> GenServer.whereis()
  end

  @spec lookup(endpoint(), role()) :: nil | {pid(), value()}
  def lookup(endpoint, role \\ nil) do
    __MODULE__
    |> Registry.lookup(key(endpoint, role))
    |> List.first()
  end

  @spec select(:ets.match_spec()) :: [term()]
  def select(spec), do: Registry.select(__MODULE__, spec)

  defp key(endpoint, nil), do: endpoint
  defp key(endpoint, role), do: {endpoint, role}
end
