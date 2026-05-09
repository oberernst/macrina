defmodule Macrina.Observe.ClientSession do
  @moduledoc false

  # Pure client-side observe bookkeeping: the subscriptions this connection
  # initiated, their last-seen sequence number, and any in-flight Block2
  # transfers. Lives as a field on `Macrina.Peer.State`; the effectful
  # `Macrina.Peer.Session` drives it with socket I/O.

  alias Macrina.Observe.Subscription

  @type entry :: %{
          last_observe: non_neg_integer() | nil,
          subscription: Subscription.t(),
          token: binary(),
          transfers: map()
        }

  @type t :: %{optional(binary()) => entry()}

  @spec new() :: t()
  def new, do: %{}

  @spec put(t(), Subscription.t(), non_neg_integer() | nil) :: t()
  def put(session, %Subscription{} = subscription, observe_value)
      when is_map(session) do
    entry = %{
      last_observe: observe_value,
      subscription: subscription,
      token: subscription.token,
      transfers: %{}
    }

    Map.put(session, subscription.token, entry)
  end

  @spec fetch(t(), binary()) :: {:ok, entry()} | :error
  def fetch(session, token) when is_map(session) and is_binary(token) do
    Map.fetch(session, token)
  end

  @spec drop(t(), binary()) :: t()
  def drop(session, token) when is_map(session) and is_binary(token) do
    Map.delete(session, token)
  end

  @spec put_transfers(t(), binary(), map()) :: t()
  def put_transfers(session, token, transfers)
      when is_map(session) and is_binary(token) and is_map(transfers) do
    case fetch(session, token) do
      {:ok, entry} -> Map.put(session, token, %{entry | transfers: transfers})
      :error -> session
    end
  end

  @spec clear_transfers(t(), binary()) :: t()
  def clear_transfers(session, token) when is_map(session) and is_binary(token) do
    put_transfers(session, token, %{})
  end

  @spec stale?(entry(), non_neg_integer() | nil) :: boolean()
  def stale?(%{last_observe: nil}, _observe_value), do: false
  def stale?(%{}, nil), do: false

  def stale?(%{last_observe: last_observe}, observe_value)
      when observe_value < last_observe,
      do: true

  def stale?(%{last_observe: last_observe, transfers: transfers}, observe_value)
      when observe_value == last_observe,
      do: map_size(transfers) == 0

  def stale?(%{}, _observe_value), do: false
end
