defmodule Macrina.ConnectionTest do
  use ExUnit.Case, async: true

  alias Macrina.{Connection, Message, Message.Opts.Block}

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

    state = %Connection{blocks: %{}}

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

    state = %Connection{blocks: %{0 => "ab", 2 => "cd"}}

    assert Connection.read_blocks(state) == nil

    assert_receive {[:macrina, :connection, :block, :missing], %{count: 1},
                    %{missing_block: 1, received_blocks: 2}}
  end
end
