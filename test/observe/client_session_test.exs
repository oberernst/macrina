defmodule Macrina.Observe.ClientSessionTest do
  use ExUnit.Case, async: true

  # Direct tests for the pure client-side observe bookkeeping extracted from
  # `Macrina.Connection.Server`. A "session" is a `%{token => entry}` map
  # tracking the subscriptions this connection initiated. The effectful shell
  # owns socket I/O; this module owns nothing but the data.

  alias Macrina.Observe.ClientSession
  alias Macrina.Observe.Subscription
  alias Macrina.Request

  # The session module never inspects the inner Request, so a minimal struct
  # is enough to satisfy `@enforce_keys` on the parent Subscription.
  defp build_subscription(token) do
    %Subscription{
      connection: self(),
      notify_to: self(),
      path: ["events"],
      request: %Request{method: :get, path: ["events"]},
      token: token
    }
  end

  describe "new/0" do
    test "returns an empty map" do
      assert ClientSession.new() == %{}
    end
  end

  describe "put/3" do
    test "indexes a fresh subscription by its token" do
      sub = build_subscription(<<1, 2, 3, 4>>)
      session = ClientSession.put(ClientSession.new(), sub, nil)

      assert {:ok, entry} = ClientSession.fetch(session, sub.token)
      assert entry.token == sub.token
      assert entry.subscription == sub
      assert entry.last_observe == nil
      assert entry.transfers == %{}
    end

    test "stores the initial Observe option value when present" do
      sub = build_subscription(<<5, 6, 7, 8>>)
      session = ClientSession.put(ClientSession.new(), sub, 42)

      assert {:ok, %{last_observe: 42}} = ClientSession.fetch(session, sub.token)
    end

    test "replacing a token resets transfers (e.g. re-subscribe)" do
      sub = build_subscription(<<9, 9, 9, 9>>)

      session =
        ClientSession.new()
        |> ClientSession.put(sub, 1)
        |> ClientSession.put_transfers(sub.token, %{<<"k">> => :placeholder})
        |> ClientSession.put(sub, 2)

      assert {:ok, %{last_observe: 2, transfers: %{}}} = ClientSession.fetch(session, sub.token)
    end
  end

  describe "fetch/2" do
    test "returns :error for unknown tokens" do
      assert ClientSession.fetch(ClientSession.new(), <<0>>) == :error
    end
  end

  describe "drop/2" do
    test "removes a token's entry" do
      sub = build_subscription(<<1>>)

      session =
        ClientSession.new()
        |> ClientSession.put(sub, nil)
        |> ClientSession.drop(sub.token)

      assert ClientSession.fetch(session, sub.token) == :error
    end

    test "is a no-op when the token is not present" do
      assert ClientSession.drop(ClientSession.new(), <<0>>) == ClientSession.new()
    end
  end

  describe "put_transfers/3 and clear_transfers/2" do
    test "updates the transfers map for a known token" do
      sub = build_subscription(<<1>>)
      transfers = %{<<"a">> => :anything}

      session =
        ClientSession.new()
        |> ClientSession.put(sub, 0)
        |> ClientSession.put_transfers(sub.token, transfers)

      assert {:ok, %{transfers: ^transfers}} = ClientSession.fetch(session, sub.token)
    end

    test "is a no-op for unknown tokens (matches Connection.Server's silent miss)" do
      session = ClientSession.put_transfers(ClientSession.new(), <<0>>, %{a: 1})

      assert session == ClientSession.new()
    end

    test "clear_transfers/2 empties an existing entry's transfers" do
      sub = build_subscription(<<1>>)

      session =
        ClientSession.new()
        |> ClientSession.put(sub, 0)
        |> ClientSession.put_transfers(sub.token, %{<<"a">> => :x})
        |> ClientSession.clear_transfers(sub.token)

      assert {:ok, %{transfers: %{}}} = ClientSession.fetch(session, sub.token)
    end
  end

  describe "stale?/2" do
    # Staleness encodes RFC 7641 §3.4: a notification is stale if its observe
    # value is strictly less than what we've already seen, OR equal but with
    # no in-flight transfers (so we are between blockwise rounds for the same
    # version and the new same-numbered notification is genuinely a no-op).

    test "is never stale before a baseline is set (last_observe: nil)" do
      entry = %{last_observe: nil, transfers: %{}}

      assert ClientSession.stale?(entry, 7) == false
      assert ClientSession.stale?(entry, nil) == false
    end

    test "is never stale when the incoming value is nil" do
      entry = %{last_observe: 5, transfers: %{}}

      assert ClientSession.stale?(entry, nil) == false
    end

    test "is stale when the incoming value is strictly less than last_observe" do
      entry = %{last_observe: 10, transfers: %{}}

      assert ClientSession.stale?(entry, 9) == true
    end

    test "is stale when equal to last_observe and there are no in-flight transfers" do
      entry = %{last_observe: 10, transfers: %{}}

      assert ClientSession.stale?(entry, 10) == true
    end

    test "is fresh when equal to last_observe but transfers are in flight" do
      entry = %{last_observe: 10, transfers: %{<<"a">> => :x}}

      assert ClientSession.stale?(entry, 10) == false
    end

    test "is fresh when the incoming value is greater than last_observe" do
      entry = %{last_observe: 10, transfers: %{}}

      assert ClientSession.stale?(entry, 11) == false
    end
  end
end
