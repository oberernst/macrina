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

  test "exchange tracks the last reply" do
    exchange = %Exchange{}

    next_exchange = Exchange.set_last_reply(exchange, <<1, 2, 3, 4>>, "cached")

    assert Exchange.last_reply(next_exchange) == {<<1, 2, 3, 4>>, "cached"}
  end
end
