defmodule Macrina.Integration.BlockPortRoamingTest do
  use ExUnit.Case, async: false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @moduletag :integration

  defmodule EchoHandler do
    def call(_state, %Message{} = message) do
      send(:test_recipient, {:assembled, message})
      Message.response(message, code: :changed, type: :ack, payload: "ok")
    end
  end

  setup do
    Process.register(self(), :test_recipient)

    name = :"endpoint_#{System.unique_integer([:positive])}"
    {:ok, endpoint_pid} = Macrina.Endpoint.start_link(handler: EchoHandler, port: 0, name: name)
    {:ok, server_socket} = Macrina.Endpoint.socket(endpoint_pid)
    {:ok, {_, server_port}} = :inet.sockname(server_socket)

    on_exit(fn -> if Process.alive?(endpoint_pid), do: GenServer.stop(endpoint_pid) end)

    {:ok, server_port: server_port}
  end

  defp open_client_socket do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false, reuseaddr: true])
    sock
  end

  defp send_block(socket, server_port, number, more, payload, token, id) do
    block = %Block{number: number, size: 16, more: more}

    msg = %Message{
      id: id,
      token: token,
      type: :con,
      code: :put,
      descriptive_block: block,
      control_block: nil,
      options: [{"Uri-Path", "upload"}, {"Block1", block}],
      payload: payload
    }

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, server_port, Message.encode(msg))
  end

  defp recv(socket) do
    {:ok, {_ip, _port, packet}} = :gen_udp.recv(socket, 0, 1_000)
    {:ok, msg} = Message.decode(packet)
    msg
  end

  test "block 0 from port A and block 1 from port B assemble into one upload",
       %{server_port: server_port} do
    token = :crypto.strong_rand_bytes(8)

    socket_a = open_client_socket()
    socket_b = open_client_socket()

    on_exit(fn ->
      :gen_udp.close(socket_a)
      :gen_udp.close(socket_b)
    end)

    send_block(socket_a, server_port, 0, true, "aaaa", token, 1)
    ack0 = recv(socket_a)
    assert ack0.code == :continue
    assert ack0.type == :ack

    send_block(socket_b, server_port, 1, false, "bbbb", token, 2)
    final = recv(socket_b)
    assert final.code == :changed
    assert final.payload == "ok"

    assert_received {:assembled, %Message{payload: "aaaabbbb", token: ^token}}
  end
end
