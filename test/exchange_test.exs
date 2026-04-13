defmodule Macrina.ExchangeTest do
  use ExUnit.Case, async: true

  alias Macrina.{Exchange, Message}

  test "exchange tracks ids and tokens" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 7, token: <<9, 9, 9, 9>>, type: :con)

    next_exchange =
      exchange
      |> Exchange.push_id(message)
      |> Exchange.push_token(message)

    assert next_exchange.ids == [7]
    assert next_exchange.tokens == [<<9, 9, 9, 9>>]

    cleared_exchange =
      next_exchange
      |> Exchange.pop_id(message)
      |> Exchange.pop_token(message)

    assert cleared_exchange.ids == []
    assert cleared_exchange.tokens == []
  end

  test "exchange registers requests and pops callers by token" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 8, token: <<1, 2, 3, 4>>, type: :con)
    from = {self(), make_ref()}

    next_exchange = Exchange.register_request(exchange, message, from)

    assert next_exchange.callers == [{<<1, 2, 3, 4>>, from}]
    assert next_exchange.ids == [8]
    assert next_exchange.tokens == [<<1, 2, 3, 4>>]

    {caller, claimed_exchange} = Exchange.pop_caller_for_token(next_exchange, message.token)

    assert caller == {<<1, 2, 3, 4>>, from}
    assert claimed_exchange.callers == []

    completed_exchange = Exchange.complete_request(claimed_exchange, message)

    assert completed_exchange.ids == []
    assert completed_exchange.tokens == []
  end

  test "exchange caches replies by message id" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 15, token: <<1, 2, 3, 4>>, type: :con)

    next_exchange = Exchange.cache_reply(exchange, message, "cached")

    assert Exchange.cached_reply(next_exchange, message) == {:ok, "cached"}
  end

  test "exchange caches nil replies for duplicate suppression" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 16, token: <<4, 3, 2, 1>>, type: :con)

    next_exchange = Exchange.cache_reply(exchange, message, nil)

    assert Exchange.cached_reply(next_exchange, message) == {:ok, nil}
  end

  test "exchange cache entries expire outside the exchange lifetime" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 19, token: <<1, 9, 1, 9>>, type: :con)

    next_exchange = Exchange.cache_reply(exchange, message, "cached", 10)

    assert Exchange.cached_reply(next_exchange, message, 14, 5) == {:ok, "cached"}
    assert Exchange.cached_reply(next_exchange, message, 15, 5) == :error
  end

  test "exchange tracks pending requests through ack and completion" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 17, token: <<7, 7, 7, 7>>, type: :con)
    from = {self(), make_ref()}

    next_exchange =
      exchange
      |> Exchange.register_request(message, from)
      |> Exchange.track_request(message, from, "packet", 2)

    assert {:ok, pending_request} = Exchange.pending_request(next_exchange, message.token)
    assert pending_request.state == :awaiting_ack
    assert pending_request.packet == "packet"

    {acknowledged_request, acknowledged_exchange} =
      Exchange.acknowledge_request(next_exchange, message)

    assert acknowledged_request.id == 17
    assert {:ok, pending_request} = Exchange.pending_request(acknowledged_exchange, message.token)
    assert pending_request.state == :awaiting_response
    assert pending_request.packet == nil

    {completed_request, completed_exchange} =
      Exchange.complete_pending_request(acknowledged_exchange, message.token)

    assert completed_request.id == 17
    assert completed_exchange.callers == []
    assert completed_exchange.ids == []
    assert completed_exchange.tokens == []
    assert Exchange.pending_request(completed_exchange, message.token) == :error
  end

  test "exchange retries pending requests and times them out" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 18, token: <<8, 8, 8, 8>>, type: :con)
    from = {self(), make_ref()}

    tracked_exchange =
      exchange
      |> Exchange.register_request(message, from)
      |> Exchange.track_request(message, from, "packet", 1)

    assert {{:retransmit, retransmit_request}, retransmitting_exchange} =
             Exchange.retry_request(tracked_exchange, message.token)

    assert retransmit_request.attempts == 1
    assert retransmit_request.packet == "packet"

    assert {{:timeout, timed_out_request}, timed_out_exchange} =
             Exchange.retry_request(retransmitting_exchange, message.token)

    assert timed_out_request.id == 18
    assert Exchange.pending_request(timed_out_exchange, message.token) == :error
  end

  test "exchange times out acknowledged requests that never receive a response" do
    exchange = %Exchange{}
    message = Message.build!(:get, id: 20, token: <<2, 0, 2, 0>>, type: :con)
    from = {self(), make_ref()}

    acknowledged_exchange =
      exchange
      |> Exchange.register_request(message, from)
      |> Exchange.track_request(message, from, "packet", 2)
      |> then(fn tracked_exchange ->
        {_request, next_exchange} = Exchange.acknowledge_request(tracked_exchange, message)
        next_exchange
      end)

    assert {{:timeout, timed_out_request}, timed_out_exchange} =
             Exchange.retry_request(acknowledged_exchange, message.token)

    assert timed_out_request.id == 20
    assert timed_out_request.state == :awaiting_response
    assert Exchange.pending_request(timed_out_exchange, message.token) == :error
  end
end
