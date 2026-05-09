defmodule Macrina.Peer.StateTest do
  use ExUnit.Case, async: true

  alias Macrina.{Blockwise, Exchange, Message, Message.Opts.Block, Peer.State}

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  test "store_block and read_blocks emit received and assembled telemetry" do
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

    state = %State{exchange: %Exchange{}}

    message = %Message{
      descriptive_block: %Block{number: 0, more: false, size: 16},
      payload: "hello"
    }

    assert {:ok, next_state} = State.store_block(state, message)

    assert_receive {[:macrina, :connection, :block, :received],
                    %{block_number: 0, block_size: 16, bytes: 5}, %{more: false}}

    assert State.read_blocks(next_state, message) == "hello"

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

    message = %Message{
      code: :put,
      descriptive_block: %Block{number: 0, more: true, size: 16},
      token: <<1>>
    }

    key = Blockwise.transfer_key(message)

    exchange = %Exchange{
      blocks: %{
        key => %{
          blocks: %{0 => "ab", 2 => "cd"},
          bytes: 4,
          content_format: nil,
          next_block: 3,
          size: 16
        }
      }
    }

    state = %State{exchange: exchange}

    assert State.read_blocks(state, message) == nil

    assert_receive {[:macrina, :connection, :block, :missing], %{count: 1},
                    %{missing_block: 1, received_blocks: 2}}
  end

  test "connection wraps exchange state helpers" do
    state = %State{exchange: %Exchange{}}
    message = Message.build!(:get, id: 41, token: <<1, 2, 3, 4>>, type: :con)
    from = {self(), make_ref()}

    next_state =
      state
      |> State.register_request(message, from)
      |> State.cache_reply(message, "reply")

    assert next_state.exchange.callers == [{<<1, 2, 3, 4>>, from}]
    assert next_state.exchange.ids == [41]
    assert next_state.exchange.tokens == [<<1, 2, 3, 4>>]
    assert State.cached_reply(next_state, message) == {:ok, "reply"}

    {caller, claimed_state} = State.pop_caller_for_token(next_state, message.token)

    assert caller == {<<1, 2, 3, 4>>, from}
    assert claimed_state.exchange.callers == []

    cleared_state =
      claimed_state
      |> State.complete_request(message)
      |> State.reset_blocks()

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

    expired_state = %State{exchange: expired_exchange, exchange_lifetime: 0}

    fresh_state = %State{
      exchange: fresh_exchange,
      exchange_lifetime: :math.pow(10, 12) |> trunc()
    }

    assert State.cached_reply(expired_state, message) == :error
    assert State.cached_reply(fresh_state, message) == {:ok, "reply"}
  end
end
