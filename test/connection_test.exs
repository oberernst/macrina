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

    next_state =
      state
      |> Connection.push_id(message)
      |> Connection.push_token(message)
      |> Connection.set_last_reply(message.token, "reply")

    assert next_state.exchange.ids == [41]
    assert next_state.exchange.tokens == [<<1, 2, 3, 4>>]
    assert Connection.last_reply(next_state) == {<<1, 2, 3, 4>>, "reply"}

    cleared_state =
      next_state
      |> Connection.pop_id(message)
      |> Connection.pop_token(message)
      |> Connection.reset_blocks()

    assert cleared_state.exchange.ids == []
    assert cleared_state.exchange.tokens == []
    assert cleared_state.exchange.blocks == %{}
  end
end
