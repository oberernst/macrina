defmodule Macrina.ServerTest do
  use ExUnit.Case, async: false

  alias Macrina.{Block1, Endpoint, Message, Message.Opts.Block, Server}

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
      send(pid, {:router_stream_chunk, chunk.complete, chunk.bytes, chunk.message.payload})

      if chunk.complete do
        Macrina.Response.new(:changed)
      end
    end
  end

  test "public server propagates block1 preferred block size" do
    policy = Block1.new!(preferred_block_size: 32)

    assert {:ok, server} = Server.start_link(handler: NilHandler, port: 0, block1: policy)

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      if Process.alive?(server) do
        GenServer.stop(server)
      end

      :gen_udp.close(client_socket)
    end)

    request =
      Message.build!(:put,
        id: 601,
        options: [{"Block1", %Block{number: 0, more: true, size: 64}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 64),
        token: <<6, 0, 1, 0>>,
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

  test "public server propagates block1 upload limits" do
    assert {:ok, server} =
             Server.start_link(handler: NilHandler, port: 0, block1: [max_body_size: 64])

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      if Process.alive?(server) do
        GenServer.stop(server)
      end

      :gen_udp.close(client_socket)
    end)

    first_request =
      Message.build!(:put,
        id: 602,
        options: [{"Block1", %Block{number: 0, more: true, size: 64}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 64),
        token: <<6, 0, 2, 0>>,
        type: :con
      )

    second_request =
      Message.build!(:put,
        id: 603,
        options: [{"Block1", %Block{number: 1, more: false, size: 64}}, {"Content-Format", 0}],
        payload: "b",
        token: <<6, 0, 2, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, first_packet)

    assert {:ok, {_ip, _port, continue_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, continue_message} = Message.decode(continue_packet)
    assert continue_message.code == :continue

    {:ok, second_packet} = Message.encode(second_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, second_packet)

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)

    assert reply_message.code == :request_entity_too_large
    assert reply_message.type == :ack
    assert reply_message.control_block == %Block{number: 1, more: false, size: 64}
  end

  test "public server rejects ambiguous block1 options" do
    assert {:error, {:invalid_block1, :conflicting_options}} =
             Server.start_link(
               handler: NilHandler,
               port: 0,
               block1: [max_body_size: 64],
               block1_max_body_size: 64
             )
  end

  test "public server streams block1 uploads through router callbacks" do
    :persistent_term.put({StreamingRouter, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({StreamingRouter, :test_pid})
    end)

    assert {:ok, server} =
             Server.start_link(router: StreamingRouter, port: 0, block1: [mode: :streaming])

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      if Process.alive?(server) do
        GenServer.stop(server)
      end

      :gen_udp.close(client_socket)
    end)

    first_request =
      Message.build!(:put,
        id: 604,
        options: [{"Block1", %Block{number: 0, more: true, size: 32}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 32),
        token: <<6, 0, 4, 0>>,
        type: :con
      )

    second_request =
      Message.build!(:put,
        id: 605,
        options: [{"Block1", %Block{number: 1, more: false, size: 32}}, {"Content-Format", 0}],
        payload: "done",
        token: <<6, 0, 4, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, first_packet)

    assert_receive {:router_stream_chunk, false, 32, first_payload}
    assert first_payload == String.duplicate("a", 32)

    assert {:ok, {_ip, _port, continue_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, continue_message} = Message.decode(continue_packet)
    assert continue_message.code == :continue

    {:ok, second_packet} = Message.encode(second_request)
    :ok = :gen_udp.send(client_socket, {127, 0, 0, 1}, server_port, second_packet)

    assert_receive {:router_stream_chunk, true, 36, "done"}

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(client_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)
    assert reply_message.code == :changed
    assert reply_message.type == :ack
  end

  test "public server rejects streaming block1 mode for routers without a callback" do
    assert {:error, {:invalid_block1, :streaming_requires_block1_callback}} =
             Server.start_link(router: NilHandler, port: 0, block1: [mode: :streaming])
  end
end
