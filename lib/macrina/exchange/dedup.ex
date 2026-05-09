defmodule Macrina.Exchange.Dedup do
  @moduledoc false

  # Pure reply-cache helpers (RFC 7252 §4.5). A "reply" is whatever was sent
  # back for a given CON message-id; caching it lets us re-send the same
  # response when a duplicate request arrives, rather than running the
  # handler twice. Operates over a `%{id => entry}` map owned by
  # `Macrina.Exchange`.

  @type entry :: %{reply: binary() | nil, stored_at: integer()}
  @type t :: %{optional(non_neg_integer()) => entry()}

  @spec new() :: t()
  def new, do: %{}

  @spec put(t(), non_neg_integer(), binary() | nil, integer()) :: t()
  def put(cache, id, reply, now)
      when is_map(cache) and is_integer(id) and (is_binary(reply) or is_nil(reply)) and
             is_integer(now) do
    Map.put(cache, id, %{reply: reply, stored_at: now})
  end

  @spec fetch(t(), non_neg_integer(), integer(), integer() | :infinity) ::
          {:ok, binary() | nil} | :error
  def fetch(cache, id, now, lifetime)
      when is_map(cache) and is_integer(id) and is_integer(now) do
    case Map.fetch(cache, id) do
      {:ok, %{reply: reply, stored_at: stored_at}} ->
        if expired?(stored_at, now, lifetime), do: :error, else: {:ok, reply}

      :error ->
        :error
    end
  end

  defp expired?(_stored_at, _now, :infinity), do: false

  defp expired?(stored_at, now, lifetime)
       when is_integer(lifetime) and lifetime >= 0 do
    now - stored_at >= lifetime
  end
end
