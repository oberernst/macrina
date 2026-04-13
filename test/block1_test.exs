defmodule Macrina.Block1Test do
  use ExUnit.Case, async: true

  alias Macrina.Block1

  test "new builds a policy with defaults" do
    assert {:ok, policy} = Block1.new()

    assert policy.max_body_size == :infinity
    assert policy.mode == :atomic
    assert policy.preferred_block_size == nil
  end

  test "new builds a policy from keyword options" do
    assert {:ok, policy} =
             Block1.new(max_body_size: 4096, mode: :streaming, preferred_block_size: 256)

    assert policy.max_body_size == 4096
    assert policy.mode == :streaming
    assert policy.preferred_block_size == 256
  end

  test "new rejects an invalid mode" do
    assert {:error, {:invalid_mode, :burst}} = Block1.new(mode: :burst)
  end

  test "new rejects an invalid max body size" do
    assert {:error, {:invalid_max_body_size, -1}} = Block1.new(max_body_size: -1)
  end

  test "new rejects an invalid preferred block size" do
    assert {:error, {:invalid_preferred_block_size, 48}} = Block1.new(preferred_block_size: 48)
  end

  test "new validates an existing policy struct" do
    policy = %Block1{max_body_size: 128, mode: :streaming, preferred_block_size: 64}

    assert {:ok, ^policy} = Block1.new(policy)
  end

  test "to_connection_opts maps the policy to connection settings" do
    policy = Block1.new!(max_body_size: 1024, mode: :streaming, preferred_block_size: 128)

    assert Block1.to_connection_opts(policy) == [
             block1_max_body_size: 1024,
             block1_mode: :streaming,
             block1_preferred_block_size: 128
           ]
  end
end
