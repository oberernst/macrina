defmodule Macrina.Message.RequestTagTest do
  use ExUnit.Case, async: true

  alias Macrina.Message
  alias Macrina.Message.Opts

  describe "RFC 9175 §3.2 Request-Tag (option 292)" do
    test "is registered with the canonical name" do
      assert Opts.number("Request-Tag") == 292
      assert Opts.name(292) == "Request-Tag"
    end

    test "encodes and decodes opaquely through a round-trip" do
      tag = <<0xCA, 0xFE, 0xBA, 0xBE>>

      msg =
        Message.build!(:put,
          id: 1234,
          options: [{"Request-Tag", tag}, {"Uri-Path", "api"}],
          payload: "x",
          token: <<1, 2, 3, 4>>,
          type: :con
        )

      assert {:ok, bin} = Message.encode(msg)
      assert {:ok, decoded} = Message.decode(bin)
      assert {"Request-Tag", ^tag} = List.keyfind(decoded.options, "Request-Tag", 0)
    end

    test "is elective (not critical) — odd-numbered options 292" do
      assert rem(292, 2) == 0
    end

    test "two block1 uploads with the same token but different Request-Tags are correlated separately" do
      alias Macrina.{Blockwise, Exchange}
      alias Macrina.Message.Opts.Block

      token = <<0x42, 0x42, 0x42, 0x42>>

      msg = fn tag, block_n, payload, more ->
        Message.build!(:put,
          id: 1000 + block_n,
          options: [
            {"Block1", %Block{number: block_n, more: more, size: 16}},
            {"Content-Format", 0},
            {"Request-Tag", tag},
            {"Uri-Path", "upload"}
          ],
          payload: payload,
          token: token,
          type: :con
        )
      end

      body_a_block_0 = msg.(<<0x01>>, 0, String.duplicate("A", 16), true)
      body_b_block_0 = msg.(<<0x02>>, 0, String.duplicate("B", 16), true)

      {:ok, exchange_a} = Exchange.store_block(%Exchange{}, body_a_block_0)
      {:ok, exchange_ab} = Exchange.store_block(exchange_a, body_b_block_0)

      assert {:ok, %{bytes: 16}} = Blockwise.transfer(exchange_ab.blocks, body_a_block_0)
      assert {:ok, %{bytes: 16}} = Blockwise.transfer(exchange_ab.blocks, body_b_block_0)

      assert map_size(exchange_ab.blocks) == 2
    end

    test "is repeatable across blocks of a single body" do
      tag = <<0x01>>
      shared_opts = [{"Request-Tag", tag}, {"Uri-Path", "upload"}]

      msg1 =
        Message.build!(:put,
          id: 1,
          options: shared_opts,
          payload: "a",
          token: <<1>>,
          type: :con
        )

      msg2 =
        Message.build!(:put,
          id: 2,
          options: shared_opts,
          payload: "b",
          token: <<1>>,
          type: :con
        )

      assert {:ok, bin1} = Message.encode(msg1)
      assert {:ok, bin2} = Message.encode(msg2)
      assert {:ok, %Message{} = d1} = Message.decode(bin1)
      assert {:ok, %Message{} = d2} = Message.decode(bin2)

      assert List.keyfind(d1.options, "Request-Tag", 0) ==
               List.keyfind(d2.options, "Request-Tag", 0)
    end
  end
end
