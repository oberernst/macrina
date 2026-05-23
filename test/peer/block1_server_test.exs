defmodule Macrina.Peer.Block1ServerTest do
  use ExUnit.Case, async: true

  alias Macrina.{Block1, Exchange, Message}
  alias Macrina.Block1.Chunk
  alias Macrina.Message.Opts.Block
  alias Macrina.Peer.Block1Server

  defp block_request(number, payload, more, size \\ 16) do
    Message.build!(:put,
      id: 1000 + number,
      options: [
        {"Block1", %Block{number: number, more: more, size: size}},
        {"Content-Format", 0}
      ],
      payload: payload,
      token: <<7, 7, 7, 7>>,
      type: :con
    )
  end

  describe "atomic mode" do
    test "continue on intermediate block" do
      policy = Block1.new!()
      exchange = %Exchange{}

      {decision, next_exchange} =
        Block1Server.ingest(policy, exchange, block_request(0, "aa", true))

      assert {:continue, %Block{number: 0, more: false, size: 16}} = decision
      assert map_size(next_exchange.blocks) == 1
    end

    test "assembled with full payload on final block" do
      policy = Block1.new!()
      exchange = %Exchange{}

      {_continue, ex1} =
        Block1Server.ingest(policy, exchange, block_request(0, String.duplicate("a", 16), true))

      {_continue, ex2} =
        Block1Server.ingest(policy, ex1, block_request(1, String.duplicate("b", 16), true))

      {decision, _ex3} = Block1Server.ingest(policy, ex2, block_request(2, "cc", false))

      payload = String.duplicate("a", 16) <> String.duplicate("b", 16) <> "cc"
      assert {:assembled, ^payload, %Block{number: 2, more: false, size: 16}} = decision
    end

    test "incomplete when the final block arrives with a gap" do
      policy = Block1.new!()

      {_decision, ex1} =
        Block1Server.ingest(
          policy,
          %Exchange{},
          block_request(0, String.duplicate("a", 16), true)
        )

      {decision, _ex} = Block1Server.ingest(policy, ex1, block_request(2, "cc", false))

      assert {:incomplete, %Block{number: 2, more: false, size: 16}} = decision
    end
  end

  describe "size limit (RFC 7959 §2.5)" do
    test "too_large when accumulated bytes exceed max_body_size" do
      policy = Block1.new!(max_body_size: 4)
      exchange = %Exchange{}

      {_decision, ex1} =
        Block1Server.ingest(
          policy,
          exchange,
          block_request(0, String.duplicate("a", 16), true)
        )

      {decision, _ex} =
        Block1Server.ingest(policy, ex1, block_request(1, String.duplicate("b", 16), true))

      assert {:too_large, %Block{number: 1}} = decision
    end

    test "infinity max_body_size never rejects on size" do
      policy = Block1.new!()
      exchange = %Exchange{}

      {decision, _ex} =
        Block1Server.ingest(
          policy,
          exchange,
          block_request(0, String.duplicate("a", 1024), true, 1024)
        )

      assert {:continue, _} = decision
    end
  end

  describe "preferred_block_size negotiation" do
    test "response block size is min(preferred, requested)" do
      policy = Block1.new!(preferred_block_size: 32)
      message = block_request(0, String.duplicate("a", 64), true, 64)

      assert %Block{number: 0, more: false, size: 32} =
               Block1Server.response_block(policy, message)
    end

    test "preferred_block_size nil falls back to requested size" do
      policy = Block1.new!()
      message = block_request(0, String.duplicate("a", 16), true)

      assert %Block{number: 0, more: false, size: 16} =
               Block1Server.response_block(policy, message)
    end
  end

  describe "streaming mode" do
    test "emits a chunk decision for each block, including the final one" do
      policy = Block1.new!(mode: :streaming)
      exchange = %Exchange{}

      {decision, ex1} =
        Block1Server.ingest(policy, exchange, block_request(0, String.duplicate("a", 16), true))

      assert {:stream_chunk, %Chunk{complete: false, bytes: 16}, %Block{number: 0}} = decision

      {decision, _ex2} = Block1Server.ingest(policy, ex1, block_request(1, "tail", false))

      assert {:stream_chunk, %Chunk{complete: true}, %Block{number: 1}} = decision
    end
  end
end
