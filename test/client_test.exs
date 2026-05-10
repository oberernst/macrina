defmodule Macrina.ClientTest do
  use ExUnit.Case, async: false

  alias Macrina.{Client, Endpoint, Message, Message.Opts.Block, Request, Response}

  defmodule TestHandler do
    def call(_connection, _message) do
      nil
    end
  end

  test "client request reassembles block2 responses" do
    payload = "abcdefghijklmnopQRST"
    test_pid = self()

    {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    server = spawn_link(fn -> block2_server_loop(server_socket, payload, test_pid) end)

    endpoint_name = {:global, {:client_test_endpoint, make_ref()}}
    {:ok, endpoint} = Endpoint.start_link(handler: TestHandler, port: 0, name: endpoint_name)
    {:ok, endpoint_socket} = Endpoint.socket(endpoint_name)

    on_exit(fn ->
      if Process.alive?(server) do
        Process.exit(server, :normal)
      end

      if Process.alive?(endpoint) do
        GenServer.stop(endpoint)
      end

      :gen_udp.close(endpoint_socket)
      :gen_udp.close(server_socket)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    assert {:ok, request} = Request.from_uri(:get, "/blocks")
    assert {:ok, response} = Client.request(client, request)

    assert response.payload == payload
    assert Response.block2(response) == %Block{number: 1, more: false, size: 16}

    assert_receive {:server_request, 0}
    assert_receive {:server_request, 1}
  end

  test "client request returns a specific block2 chunk when requested explicitly" do
    payload = "abcdefghijklmnopQRST"
    test_pid = self()

    {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    server = spawn_link(fn -> block2_server_loop(server_socket, payload, test_pid) end)

    endpoint_name = {:global, {:client_test_endpoint, make_ref()}}
    {:ok, endpoint} = Endpoint.start_link(handler: TestHandler, port: 0, name: endpoint_name)
    {:ok, endpoint_socket} = Endpoint.socket(endpoint_name)

    on_exit(fn ->
      if Process.alive?(server) do
        Process.exit(server, :normal)
      end

      if Process.alive?(endpoint) do
        GenServer.stop(endpoint)
      end

      :gen_udp.close(endpoint_socket)
      :gen_udp.close(server_socket)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    request =
      Request.from_uri!(:get, "/blocks")
      |> Request.put_block2(%Block{number: 1, more: false, size: 16})

    assert {:ok, response} = Client.request(client, request)

    assert response.payload == "QRST"
    assert Response.block2(response) == %Block{number: 1, more: false, size: 16}

    assert_receive {:server_request, 1}
    refute_receive {:server_request, 2}, 100
  end

  defp block2_server_loop(socket, payload, test_pid) do
    case :gen_udp.recv(socket, 0, 1_000) do
      {:ok, {ip, port, packet}} ->
        {:ok, request} = Message.decode(packet)
        block_number = request_block_number(request)
        send(test_pid, {:server_request, block_number})

        response = block2_response(request, payload, block_number)
        {:ok, encoded_response} = Message.encode(response)
        :ok = :gen_udp.send(socket, ip, port, encoded_response)

        block2_server_loop(socket, payload, test_pid)

      {:error, :timeout} ->
        :ok
    end
  end

  defp request_block_number(%Message{control_block: %Block{number: number}}) do
    number
  end

  defp request_block_number(%Message{}) do
    0
  end

  defp block2_response(request, payload, block_number) do
    block_size = 16
    offset = block_number * block_size
    remaining = byte_size(payload) - offset
    chunk_size = min(block_size, remaining)
    chunk = :binary.part(payload, offset, chunk_size)
    more = remaining > block_size

    options = [
      {"Block2", %Block{number: block_number, more: more, size: block_size}},
      {"Content-Format", 0}
    ]

    Message.build!(:content,
      id: request.id,
      options: options,
      payload: chunk,
      token: request.token,
      type: :ack
    )
  end
end
