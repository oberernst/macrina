defmodule Macrina.Exchange.DedupTest do
  use ExUnit.Case, async: true

  # Direct tests for the pure reply-cache helper extracted from
  # `Macrina.Exchange`. The cache is a plain `%{id => entry}` map; these tests
  # pin down the four primitives the exchange relies on (`new/0`, `put/4`,
  # `fetch/4`, and the implicit expiry policy under `:infinity`).

  alias Macrina.Exchange.Dedup

  describe "new/0" do
    test "returns an empty map" do
      assert Dedup.new() == %{}
    end
  end

  describe "put/4" do
    test "stores a binary reply under the message id with its timestamp" do
      cache = Dedup.put(Dedup.new(), 17, "hello", 1_000)

      assert cache == %{17 => %{reply: "hello", stored_at: 1_000}}
    end

    test "stores a nil reply (used to suppress duplicates whose handler ran but produced no reply)" do
      cache = Dedup.put(Dedup.new(), 18, nil, 2_000)

      assert cache == %{18 => %{reply: nil, stored_at: 2_000}}
    end

    test "overwrites a previously cached entry for the same id" do
      cache =
        Dedup.new()
        |> Dedup.put(19, "first", 1_000)
        |> Dedup.put(19, "second", 1_500)

      assert cache == %{19 => %{reply: "second", stored_at: 1_500}}
    end

    test "preserves entries for unrelated ids" do
      cache =
        Dedup.new()
        |> Dedup.put(20, "a", 1_000)
        |> Dedup.put(21, "b", 1_100)

      assert Map.keys(cache) |> Enum.sort() == [20, 21]
    end
  end

  describe "fetch/4" do
    test "returns :error for an unknown id" do
      assert Dedup.fetch(Dedup.new(), 99, 0, :infinity) == :error
    end

    test "returns {:ok, reply} when the entry has not expired" do
      cache = Dedup.put(Dedup.new(), 22, "cached", 1_000)

      assert Dedup.fetch(cache, 22, 1_500, 1_000) == {:ok, "cached"}
    end

    test "returns {:ok, nil} for entries that cached a nil reply" do
      cache = Dedup.put(Dedup.new(), 23, nil, 2_000)

      assert Dedup.fetch(cache, 23, 2_100, 1_000) == {:ok, nil}
    end

    test "returns :error once the entry's age meets or exceeds the lifetime" do
      cache = Dedup.put(Dedup.new(), 24, "stale", 1_000)

      # exactly at the boundary is considered expired (age >= lifetime)
      assert Dedup.fetch(cache, 24, 2_000, 1_000) == :error
      # strictly past the boundary too
      assert Dedup.fetch(cache, 24, 5_000, 1_000) == :error
    end

    test "treats a lifetime of :infinity as never expiring" do
      cache = Dedup.put(Dedup.new(), 25, "forever", 1_000)

      assert Dedup.fetch(cache, 25, 1_000_000_000, :infinity) == {:ok, "forever"}
    end

    test "returns the entry when age is just under the lifetime" do
      cache = Dedup.put(Dedup.new(), 26, "fresh", 1_000)

      assert Dedup.fetch(cache, 26, 1_999, 1_000) == {:ok, "fresh"}
    end
  end
end
