defmodule Macrina.ConnectionTest do
  use ExUnit.Case, async: true

  alias Macrina.{Connection, Exchange, Message, Message.Opts.Block}

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  test "push_block and read_blocks emit received and assembled telemetry" do
    handler_id = "connection-block-events-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:macrina, :connection, :block, :received],
          [:macrina, :connection, :block, :assembled]
        ],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    state = %Connection{exchange: %Exchange{}}

    message = %Message{
      descriptive_block: %Block{number: 0, more: false, size: 16},
      payload: "hello"
    }

    next_state = Connection.push_block(state, message)

    assert_receive {[:macrina, :connection, :block, :received],
                    %{block_number: 0, block_size: 16, bytes: 5}, %{more: false}}

    assert Connection.read_blocks(next_state) == "hello"

    assert_receive {[:macrina, :connection, :block, :assembled], %{bytes: 5, count: 1},
                    %{first_block: 0, last_block: 0}}
  end

  test "read_blocks emits missing telemetry when a block is absent" do
    handler_id = "connection-missing-block-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:macrina, :connection, :block, :missing],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    exchange = %Exchange{blocks: %{0 => "ab", 2 => "cd"}}
    state = %Connection{exchange: exchange}

    assert Connection.read_blocks(state) == nil

    assert_receive {[:macrina, :connection, :block, :missing], %{count: 1},
                    %{missing_block: 1, received_blocks: 2}}
  end

  test "connection wraps exchange state helpers" do
    state = %Connection{exchange: %Exchange{}}
    message = Message.build!(:get, id: 41, token: <<1, 2, 3, 4>>, type: :con)
    from = {self(), make_ref()}

    next_state =
      state
      |> Connection.register_request(message, from)
      |> Connection.cache_reply(message, "reply")

    assert next_state.exchange.callers == [{<<1, 2, 3, 4>>, from}]
    assert next_state.exchange.ids == [41]
    assert next_state.exchange.tokens == [<<1, 2, 3, 4>>]
    assert Connection.cached_reply(next_state, message) == {:ok, "reply"}

    {caller, claimed_state} = Connection.pop_caller_for_token(next_state, message.token)

    assert caller == {<<1, 2, 3, 4>>, from}
    assert claimed_state.exchange.callers == []

    cleared_state =
      claimed_state
      |> Connection.complete_request(message)
      |> Connection.reset_blocks()

    assert cleared_state.exchange.ids == []
    assert cleared_state.exchange.tokens == []
    assert cleared_state.exchange.blocks == %{}
  end

  test "connection cached_reply respects exchange lifetime" do
    message = Message.build!(:get, id: 42, token: <<4, 2, 4, 2>>, type: :con)

    expired_exchange =
      %Exchange{}
      |> Exchange.cache_reply(message, "reply", -1_000_000_000_000)

    fresh_exchange =
      %Exchange{}
      |> Exchange.cache_reply(message, "reply")

    expired_state = %Connection{exchange: expired_exchange, exchange_lifetime: 0}

    fresh_state = %Connection{
      exchange: fresh_exchange,
      exchange_lifetime: :math.pow(10, 12) |> trunc()
    }

    assert Connection.cached_reply(expired_state, message) == :error
    assert Connection.cached_reply(fresh_state, message) == {:ok, "reply"}
  end
end
