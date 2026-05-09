defmodule Macrina.Message.Opts.BinaryTest do
  use ExUnit.Case, async: true

  # Direct tests for the binary codec helpers — particularly `decode_block`
  # and `encode_block`, which Wave C is rewriting to use `Bitwise` and a
  # 7-entry size lookup table in place of `:math.pow`/`:math.log2`.

  alias Macrina.Message.Opts.Binary
  alias Macrina.Message.Opts.Block

  # CoAP block-size encoding (RFC 7959 §2.2):
  #   szx 0..6 → size 16, 32, 64, 128, 256, 512, 1024
  #   szx 7    → reserved (size 2048 in the formula but disallowed by spec)
  @valid_szx_to_size [
    {0, 16},
    {1, 32},
    {2, 64},
    {3, 128},
    {4, 256},
    {5, 512},
    {6, 1024}
  ]

  describe "decode_block/3 (raw num/m/szx form)" do
    for {szx, size} <- @valid_szx_to_size do
      test "szx=#{szx} decodes to size=#{size}" do
        assert %Block{number: 0, more: false, size: unquote(size)} =
                 Binary.decode_block(0, 0, unquote(szx))
      end
    end

    test "more bit is reflected in the struct" do
      assert %Block{more: true} = Binary.decode_block(0, 1, 0)
      assert %Block{more: false} = Binary.decode_block(0, 0, 0)
    end

    test "block number is preserved verbatim" do
      assert %Block{number: 42, size: 64} = Binary.decode_block(42, 0, 2)
    end
  end

  describe "decode_block/1 (binary patterns)" do
    test "4-bit number form" do
      assert %Block{number: 5, more: true, size: 32} = Binary.decode_block(<<5::4, 1::1, 1::3>>)
    end

    test "12-bit number form" do
      assert %Block{number: 100, more: false, size: 64} =
               Binary.decode_block(<<100::12, 0::1, 2::3>>)
    end

    test "28-bit number form" do
      assert %Block{number: 1_000_000, more: true, size: 1024} =
               Binary.decode_block(<<1_000_000::28, 1::1, 6::3>>)
    end
  end

  describe "validate/1" do
    # `validate/1` runs the same shape+name+value checks as `encode/1` but
    # stops short of allocating the encoded options binary. Wave C added it
    # so `Macrina.Message.build/2` can validate options at build time without
    # paying for an encoding pass that gets thrown away.

    test "returns :ok for an empty option list" do
      assert Binary.validate([]) == :ok
    end

    test "returns :ok for a list of well-formed registered options" do
      options = [{"Uri-Path", "events"}, {"Content-Format", 0}, {"Accept", 50}]
      assert Binary.validate(options) == :ok
    end

    test "returns an error for unknown option names" do
      assert Binary.validate([{"Unknown-Option", "value"}]) ==
               {:error, {:unknown_option, "Unknown-Option"}}
    end

    test "returns an error for malformed value types" do
      # Content-Format is registered as UINT; a string is invalid.
      assert Binary.validate([{"Content-Format", "text/plain"}]) ==
               {:error, {:invalid_option_value, "Content-Format", "text/plain"}}
    end

    test "returns an error for non-list inputs" do
      assert Binary.validate("not a list") == {:error, :invalid_options}
      assert Binary.validate(%{}) == {:error, :invalid_options}
    end

    test "returns an error for option entries that are not 2-tuples" do
      assert {:error, {:invalid_option, _}} = Binary.validate([:not_a_tuple])
    end
  end

  describe "encode_block/3" do
    for {_szx, size} <- @valid_szx_to_size do
      test "size=#{size} round-trips through encode/decode (more=false)" do
        encoded = Binary.encode_block(0, false, unquote(size))
        assert %Block{number: 0, more: false, size: unquote(size)} = Binary.decode_block(encoded)
      end

      test "size=#{size} round-trips through encode/decode (more=true) [encode/decode]" do
        encoded = Binary.encode_block(7, true, unquote(size))
        assert %Block{number: 7, more: true, size: unquote(size)} = Binary.decode_block(encoded)
      end
    end

    test "encodes 4-bit numbers (num < 16) into 1 byte" do
      assert byte_size(Binary.encode_block(0, false, 16)) == 1
      assert byte_size(Binary.encode_block(15, false, 16)) == 1
    end

    test "encodes 12-bit numbers (16 ≤ num < 4096) into 2 bytes" do
      assert byte_size(Binary.encode_block(16, false, 16)) == 2
      assert byte_size(Binary.encode_block(4095, false, 16)) == 2
    end

    test "encodes 28-bit numbers (num ≥ 4096) into the wider form" do
      encoded = Binary.encode_block(4096, false, 16)
      # 28 bits number + 1 bit more + 3 bits szx = 32 bits = 4 bytes
      assert byte_size(encoded) == 4
    end
  end
end
