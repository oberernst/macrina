defmodule Macrina.BlockTransferTest do
  use ExUnit.Case, async: true

  alias Macrina.BlockTransfer
  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  defmodule NilHandler do
    def call(_state, _message), do: nil
  end

  defp block_msg(number, payload, more, token \\ <<1, 2, 3, 4>>, id \\ 100) do
    %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      payload: payload,
      options: []
    }
  end

  defp start_transfer(opts \\ []) do
    defaults = [ip: {127, 0, 0, 1}, token: <<1, 2, 3, 4>>, handler: NilHandler]
    {:ok, pid} = BlockTransfer.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe "handle_block/2 in :assembling phase" do
    test "returns :continue with a 2.31 ACK binary when more: true" do
      pid = start_transfer()

      assert {:continue, ack_bin} = BlockTransfer.handle_block(pid, block_msg(0, "abc", true))

      assert is_binary(ack_bin)
      {:ok, ack} = Message.decode(ack_bin)
      assert ack.code == :continue
      assert ack.type == :ack
    end

    test "returns :assembled with the full message when more: false and blocks are contiguous" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", true))

      assert {:assembled, %Message{payload: "aabbcc"} = full} =
               BlockTransfer.handle_block(pid, block_msg(2, "cc", false))

      assert full.token == <<1, 2, 3, 4>>
    end

    test "returns :incomplete with a 4.08 ACK when more: false and a block is missing" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))

      assert {:incomplete, bin} = BlockTransfer.handle_block(pid, block_msg(2, "cc", false))

      {:ok, msg} = Message.decode(bin)
      assert msg.code == :request_entity_incomplete
      assert msg.type == :ack
    end
  end

  describe "cache_completion and :duplicate" do
    test "after cache_completion, a retransmit of the final block returns :duplicate with the cached bin" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))

      reply_bin = "the-application-reply-binary"
      assert :ok = BlockTransfer.cache_completion(pid, reply_bin)

      assert {:duplicate, ^reply_bin} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
    end

    test "cache_completion with nil yields {:duplicate, nil} on retransmit" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))

      assert :ok = BlockTransfer.cache_completion(pid, nil)

      assert {:duplicate, nil} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
    end
  end
end
