defmodule Macrina.BlockTransferTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Macrina.BlockTransfer
  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  defmodule NilHandler do
    def call(_state, _message), do: nil
  end

  defp block_msg(number, payload, more, token \\ <<1, 2, 3, 4>>, id \\ 100, opts \\ []) do
    base_opts = [{"Uri-Path", "upload"}]
    extra = Keyword.get(opts, :options, [])

    %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      payload: payload,
      options: base_opts ++ extra
    }
  end

  defp start_transfer(opts \\ []) do
    defaults = [
      ip: {127, 0, 0, 1},
      port: 5683,
      uri_path: ["upload"],
      uri_query: [],
      request_tag: nil,
      discriminator: <<1, 2, 3, 4>>,
      handler: NilHandler
    ]

    {:ok, pid} = BlockTransfer.start_link(Keyword.merge(defaults, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe "handle_block/3 in :assembling phase" do
    test "returns :continue with a 2.31 ACK binary when more: true" do
      pid = start_transfer()

      assert {:continue, ack_bin} =
               BlockTransfer.handle_block(pid, 5683, block_msg(0, "abc", true))

      assert is_binary(ack_bin)
      {:ok, ack} = Message.decode(ack_bin)
      assert ack.code == :continue
      assert ack.type == :ack
    end

    test "returns :assembled with the full message when more: false and blocks are contiguous" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))
      assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", true))

      assert {:assembled, %Message{payload: "aabbcc"} = full} =
               BlockTransfer.handle_block(pid, 5683, block_msg(2, "cc", false))

      assert full.token == <<1, 2, 3, 4>>
    end

    test "returns :incomplete with a 4.08 ACK when more: false and a block is missing" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))

      assert {:incomplete, bin} = BlockTransfer.handle_block(pid, 5683, block_msg(2, "cc", false))

      {:ok, msg} = Message.decode(bin)
      assert msg.code == :request_entity_incomplete
      assert msg.type == :ack
    end
  end

  describe "cache_completion and :duplicate" do
    test "after cache_completion, a retransmit of the final block returns :duplicate with the cached bin" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))

      reply_bin = "the-application-reply-binary"
      assert :ok = BlockTransfer.cache_completion(pid, reply_bin)

      assert {:duplicate, ^reply_bin} =
               BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))
    end

    test "cache_completion with nil yields {:duplicate, nil} on retransmit" do
      pid = start_transfer()

      assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))
      assert {:assembled, _} = BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))

      assert :ok = BlockTransfer.cache_completion(pid, nil)

      assert {:duplicate, nil} = BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))
    end
  end

  describe "info-level logging across the lifecycle" do
    test "logs [BlockTransfer] block accepted with block number and assembled total" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer()
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))

          assert {:assembled, _} =
                   BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))

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
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))

          assert {:incomplete, _} =
                   BlockTransfer.handle_block(pid, 5683, block_msg(2, "cc", false))
        end)

      assert log =~ "[BlockTransfer] blocks incomplete"
      assert log =~ "missing=1"
      assert log =~ "have=2"
    end

    test "logs [BlockTransfer] duplicate final block once cached" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer()
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))

          assert {:assembled, _} =
                   BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))

          assert :ok = BlockTransfer.cache_completion(pid, "reply")

          assert {:duplicate, _} =
                   BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))
        end)

      assert log =~ "[BlockTransfer] duplicate final block"
      assert log =~ "cached=true"
    end

    test "peer metadata accumulates every ip:port that delivered a block" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer(port: 5683)
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5684, block_msg(1, "bb", true))

          assert {:assembled, _} =
                   BlockTransfer.handle_block(pid, 5685, block_msg(2, "cc", false))
        end)

      assert log =~ "peer=127.0.0.1:5683,127.0.0.1:5684,127.0.0.1:5685"
    end

    test "peer metadata does not duplicate a port seen twice in a row" do
      log =
        capture_log([level: :info], fn ->
          pid = start_transfer(port: 5683)
          assert {:continue, _} = BlockTransfer.handle_block(pid, 5683, block_msg(0, "aa", true))

          assert {:assembled, _} =
                   BlockTransfer.handle_block(pid, 5683, block_msg(1, "bb", false))
        end)

      refute log =~ "127.0.0.1:5683,127.0.0.1:5683"
      assert log =~ "peer=127.0.0.1:5683 "
    end
  end

  describe "handle_block/4 with :global registration (RFC 9175 correlation)" do
    setup do
      ip = {127, 0, 0, 1}
      token = :crypto.strong_rand_bytes(8)

      on_exit(fn ->
        for name <- :global.registered_names(),
            match?({Macrina.BlockTransfer, ^ip, _, _, _}, name) do
          case :global.whereis_name(name) do
            :undefined -> :ok
            pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
          end
        end
      end)

      {:ok, ip: ip, token: token}
    end

    test "without Request-Tag, key falls back to the Token (NCS 2.2.54 legacy)",
         %{ip: ip, token: token} do
      msg = block_msg(0, "aa", true, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg)

      pid = :global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token})
      assert is_pid(pid)
    end

    test "second call resolves the same pid", %{ip: ip, token: token} do
      msg0 = block_msg(0, "aa", true, token)
      msg1 = block_msg(1, "bb", false, token)

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg0)
      pid_after_first = :global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token})

      assert {:assembled, %Message{payload: "aabb"}} =
               BlockTransfer.handle_block(ip, 5683, NilHandler, msg1)

      pid_after_second = :global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token})
      assert pid_after_first == pid_after_second
    end

    test "two sequential bodies on same path with distinct stable tokens get separate buffers (NCS 2.2.54)",
         %{ip: ip} do
      token_a = <<1, 1, 1, 1, 1, 1, 1, 1>>
      token_b = <<2, 2, 2, 2, 2, 2, 2, 2>>

      a0 = block_msg(0, "aa", true, token_a, 1)
      a1 = block_msg(1, "AA", false, token_a, 2)
      b0 = block_msg(0, "bb", true, token_b, 3)
      b1 = block_msg(1, "BB", false, token_b, 4)

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, a0)

      assert {:assembled, %Message{payload: "aaAA"}} =
               BlockTransfer.handle_block(ip, 5683, NilHandler, a1)

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, b0)

      assert {:assembled, %Message{payload: "bbBB"}} =
               BlockTransfer.handle_block(ip, 5683, NilHandler, b1)

      assert is_pid(:global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token_a}))
      assert is_pid(:global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token_b}))
    end

    test "blocks with rotating tokens but identical Request-Tag reassemble (RFC 9175)",
         %{ip: ip} do
      tag = <<0xFF, 0xD0, 0x5A, 0x98, 0xCF, 0x63, 0xFA, 0xF8>>
      token_a = <<1, 1, 1, 1, 1, 1, 1, 1>>
      token_b = <<2, 2, 2, 2, 2, 2, 2, 2>>

      msg0 = block_msg(0, "aa", true, token_a, 1, options: [{"Request-Tag", tag}])
      msg1 = block_msg(1, "bb", false, token_b, 2, options: [{"Request-Tag", tag}])

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg0)

      assert {:assembled, %Message{payload: "aabb", token: ^token_b}} =
               BlockTransfer.handle_block(ip, 5683, NilHandler, msg1)

      pid = :global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], tag})
      assert is_pid(pid)
    end

    test "two concurrent bodies with different Request-Tags stay isolated (RFC 9175)",
         %{ip: ip} do
      tag_a = <<0xAA, 0xAA>>
      tag_b = <<0xBB, 0xBB>>
      token_a = <<1, 1, 1, 1, 1, 1, 1, 1>>
      token_b = <<2, 2, 2, 2, 2, 2, 2, 2>>

      a0 = block_msg(0, "aa", true, token_a, 10, options: [{"Request-Tag", tag_a}])
      a1 = block_msg(1, "AA", false, token_a, 11, options: [{"Request-Tag", tag_a}])
      b0 = block_msg(0, "bb", true, token_b, 20, options: [{"Request-Tag", tag_b}])
      b1 = block_msg(1, "BB", false, token_b, 21, options: [{"Request-Tag", tag_b}])

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, a0)
      assert {:continue, _} = BlockTransfer.handle_block(ip, 5684, NilHandler, b0)

      assert {:assembled, %Message{payload: "bbBB"}} =
               BlockTransfer.handle_block(ip, 5684, NilHandler, b1)

      assert {:assembled, %Message{payload: "aaAA"}} =
               BlockTransfer.handle_block(ip, 5683, NilHandler, a1)
    end

    test "different Uri-Path correlates to different buffers when no Request-Tag", %{ip: ip} do
      token = <<9, 9, 9, 9, 9, 9, 9, 9>>

      msg_upload = %Message{
        id: 1,
        token: token,
        type: :con,
        code: :put,
        descriptive_block: %Block{number: 0, more: true, size: 2},
        options: [{"Uri-Path", "upload"}],
        payload: "aa"
      }

      msg_other = %Message{
        id: 2,
        token: token,
        type: :con,
        code: :put,
        descriptive_block: %Block{number: 0, more: true, size: 2},
        options: [{"Uri-Path", "other"}],
        payload: "xx"
      }

      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg_upload)
      assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg_other)

      assert is_pid(:global.whereis_name({Macrina.BlockTransfer, ip, ["upload"], [], token}))
      assert is_pid(:global.whereis_name({Macrina.BlockTransfer, ip, ["other"], [], token}))
    end

    test "ports observed across calls accumulate in peer metadata", %{ip: ip, token: token} do
      msg0 = block_msg(0, "aa", true, token)
      msg1 = block_msg(1, "bb", false, token)

      log =
        capture_log([level: :info], fn ->
          assert {:continue, _} = BlockTransfer.handle_block(ip, 5683, NilHandler, msg0)
          assert {:assembled, _} = BlockTransfer.handle_block(ip, 5684, NilHandler, msg1)
        end)

      assert log =~ "peer=127.0.0.1:5683,127.0.0.1:5684"
    end
  end
end
