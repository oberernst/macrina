defmodule Macrina.BlocksTest do
  use ExUnit.Case, async: true

  alias Macrina.Blocks
  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  defp block_msg(number, payload, more) do
    %Message{
      descriptive_block: %Block{number: number, size: byte_size(payload), more: more},
      payload: payload
    }
  end

  describe "empty/0" do
    test "starts as an empty map" do
      assert Blocks.empty() == %{}
    end
  end

  describe "push/2" do
    test "stores the payload under the block number" do
      acc = Blocks.empty() |> Blocks.push(block_msg(0, "abc", true))
      assert acc == %{0 => "abc"}
    end

    test "accepts blocks out of order" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(1, "def", false))
        |> Blocks.push(block_msg(0, "abc", true))

      assert acc == %{0 => "abc", 1 => "def"}
    end

    test "later push for the same number overwrites earlier" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "abc", true))
        |> Blocks.push(block_msg(0, "xyz", true))

      assert acc == %{0 => "xyz"}
    end
  end

  describe "read/1" do
    test "returns the concatenated payload when blocks 0..N are contiguous" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(1, "bb", true))
        |> Blocks.push(block_msg(2, "cc", false))

      assert Blocks.read(acc) == {:ok, "aabbcc"}
    end

    test "reads correctly when blocks were pushed out of order" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(2, "cc", false))
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(1, "bb", true))

      assert Blocks.read(acc) == {:ok, "aabbcc"}
    end

    test "reports the first missing block on a gap" do
      acc =
        Blocks.empty()
        |> Blocks.push(block_msg(0, "aa", true))
        |> Blocks.push(block_msg(2, "cc", false))

      assert Blocks.read(acc) == {:error, {:missing, 1}}
    end

    test "reports missing 0 when the accumulator starts at a non-zero block" do
      acc = Blocks.empty() |> Blocks.push(block_msg(1, "bb", false))
      assert Blocks.read(acc) == {:error, {:missing, 0}}
    end

    test "reports missing 0 when empty" do
      assert Blocks.read(Blocks.empty()) == {:error, {:missing, 0}}
    end
  end
end
