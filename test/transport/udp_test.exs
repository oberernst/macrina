defmodule Macrina.Transport.UDPTest do
  use ExUnit.Case, async: false

  alias Macrina.{Block1, Message, Message.Opts.Block, Transport.UDP}

  defmodule NilHandler do
    def call(_connection, _message) do
      nil
    end
  end

  defmodule StreamingRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      Macrina.Response.new(:changed)
    end

    @impl true
    def block1(chunk, _context) do
      pid = :persistent_term.get({__MODULE__, :test_pid})
      send(pid, {:endpoint_router_chunk, chunk.complete, chunk.bytes, chunk.message.payload})

      if chunk.complete do
        Macrina.Response.new(:changed)
      end
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  end

  test "public endpoint propagates block1 policy" do
    policy = Block1.new!(preferred_block_size: 32)

    assert {:ok, endpoint} = UDP.start_link(handler: NilHandler, port: 0, block1: policy)

    {:ok, server_socket} = UDP.socket(endpoint)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      stop_process(endpoint)
      :gen_udp.close(client_socket)
    end)

    request =
      Message.build!(:put,
        id: 701,
        options: [{"Block1", %Block{number: 0, more: true, size: 64}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 64),
        token: <<7, 0, 1, 0>>,
        type: :con
      )

    {:ok, packet} = Message.encode(request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, packet)

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)

    assert reply_message.code == :continue
    assert reply_message.type == :ack
    assert reply_message.control_block == %Block{number: 0, more: false, size: 32}
  end

  test "public endpoint streams block1 uploads through router callbacks" do
    :persistent_term.put({StreamingRouter, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({StreamingRouter, :test_pid})
    end)

    handler = {:router, StreamingRouter, %{}}

    assert {:ok, endpoint} = UDP.start_link(handler: handler, port: 0, block1: [mode: :streaming])

    {:ok, server_socket} = UDP.socket(endpoint)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      stop_process(endpoint)
      :gen_udp.close(client_socket)
    end)

    first_request =
      Message.build!(:put,
        id: 702,
        options: [{"Block1", %Block{number: 0, more: true, size: 32}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 32),
        token: <<7, 0, 2, 0>>,
        type: :con
      )

    second_request =
      Message.build!(:put,
        id: 703,
        options: [{"Block1", %Block{number: 1, more: false, size: 32}}, {"Content-Format", 0}],
        payload: "done",
        token: <<7, 0, 2, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, first_packet)

    assert_receive {:endpoint_router_chunk, false, 32, first_payload}
    assert first_payload == String.duplicate("a", 32)

    assert {:ok, {_ip, _port, continue_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, continue_message} = Message.decode(continue_packet)
    assert continue_message.code == :continue

    {:ok, second_packet} = Message.encode(second_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, second_packet)

    assert_receive {:endpoint_router_chunk, true, 36, "done"}

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)
    assert reply_message.code == :changed
    assert reply_message.type == :ack
  end

  test "public endpoint rejects streaming block1 mode for router handlers without a callback" do
    router_handler = {:router, __MODULE__.NilHandler, %{}}

    assert {:error, {:invalid_block1, :streaming_requires_block1_callback}} =
             UDP.start_link(handler: router_handler, port: 0, block1: [mode: :streaming])
  end

  describe "next_message_id/1" do
    # Wave C replaced `Enum.random(10000..19999)` per-message with a
    # per-endpoint atomic counter. The ref lives on `Macrina.Transport.UDP`
    # state; this test pins down the wrap and monotonic-modulo-65536
    # behaviour without standing up a real socket.

    test "returns sequential ids modulo 65_536 for a fresh counter" do
      ref = :atomics.new(1, signed: false)

      ids = for _ <- 1..5, do: UDP.next_message_id(ref)

      # Five sequential calls produce five consecutive values; with a fresh
      # counter that's [1, 2, 3, 4, 5].
      assert ids == [1, 2, 3, 4, 5]
    end

    test "wraps around at 65_536" do
      ref = :atomics.new(1, signed: false)
      :atomics.put(ref, 1, 65_534)

      assert UDP.next_message_id(ref) == 65_535
      assert UDP.next_message_id(ref) == 0
      assert UDP.next_message_id(ref) == 1
    end

    test "stays within the 16-bit range no matter what the underlying counter holds" do
      ref = :atomics.new(1, signed: false)
      :atomics.put(ref, 1, 1_000_000)

      id = UDP.next_message_id(ref)

      assert id >= 0 and id <= 65_535
    end
  end
end
