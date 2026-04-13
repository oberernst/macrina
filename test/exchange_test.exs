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

  test "exchange tracks the last reply" do
    exchange = %Exchange{}

    next_exchange = Exchange.set_last_reply(exchange, <<1, 2, 3, 4>>, "cached")

    assert Exchange.last_reply(next_exchange) == {<<1, 2, 3, 4>>, "cached"}
  end
end
