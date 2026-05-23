defmodule Macrina.BlockTransferTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "info-level logging across the lifecycle" do
    test "logs [BlockTransfer] block accepted with block number and assembled total" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer()
          assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
          assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
          assert :ok = BlockTransfer.cache_completion(pid, "reply")
        end)

      assert log =~ "[BlockTransfer] block accepted"
      assert log =~ "block=0"
      assert log =~ "[BlockTransfer] blocks assembled"
      assert log =~ "total_size=4"
      assert log =~ "[BlockTransfer] completion cached"
      assert log =~ "reply_size=5"
    end

    test "logs [BlockTransfer] blocks incomplete with the missing block number" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer()
          assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
          assert {:incomplete, _} = BlockTransfer.handle_block(pid, block_msg(2, "cc", false))
        end)

      assert log =~ "[BlockTransfer] blocks incomplete"
      assert log =~ "missing=1"
      assert log =~ "have=2"
    end

    test "logs [BlockTransfer] duplicate final block once cached" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer()
          assert {:continue, _} = BlockTransfer.handle_block(pid, block_msg(0, "aa", true))
          assert {:assembled, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
          assert :ok = BlockTransfer.cache_completion(pid, "reply")
          assert {:duplicate, _} = BlockTransfer.handle_block(pid, block_msg(1, "bb", false))
        end)

      assert log =~ "[BlockTransfer] duplicate final block"
      assert log =~ "cached=true"
    end
  end

  describe "handle_block/4 with :global registration" do
    setup do
      ip = {127, 0, 0, 1}
      token = :crypto.strong_rand_bytes(8)

      on_exit(fn ->
        case :global.whereis_name({Macrina.BlockTransfer, ip, token}) do
          :undefined -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      {:ok, ip: ip, token: token}
    end

    test "starts a globally-registered process on first call", %{ip: ip, token: token} do
      msg = block_msg(0, "aa", true, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, token, NilHandler, msg)

      pid = :global.whereis_name({Macrina.BlockTransfer, ip, token})
      assert is_pid(pid)
    end

    test "second call resolves the same pid", %{ip: ip, token: token} do
      msg0 = block_msg(0, "aa", true, token)
      msg1 = block_msg(1, "bb", false, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, token, NilHandler, msg0)
      pid_after_first = :global.whereis_name({Macrina.BlockTransfer, ip, token})

      assert {:assembled, %Message{payload: "aabb"}} =
               BlockTransfer.handle_block(ip, token, NilHandler, msg1)

      pid_after_second = :global.whereis_name({Macrina.BlockTransfer, ip, token})
      assert pid_after_first == pid_after_second
    end
  end
end
