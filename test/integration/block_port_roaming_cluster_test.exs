defmodule Macrina.Integration.BlockPortRoamingClusterTest do
  use ExUnit.Case, async: false

  alias Macrina.Message
  alias Macrina.Message.Opts.Block

  @moduletag :cluster
  @moduletag :integration

  defmodule EchoHandler do
    def call(_state, %Message{} = message) do
      Message.response(message, code: :changed, type: :ack, payload: "ok")
    end
  end

  setup do
    {:ok, peer, peer_node} =
      :peer.start(%{
        name: :"macrina_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1"
      })

    code_paths = :code.get_path()
    :ok = :erpc.call(peer_node, :code, :add_paths, [code_paths])
    {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:macrina])

    on_exit(fn -> :peer.stop(peer) end)

    true = Node.connect(peer_node)
    assert peer_node in Node.list()

    :global.sync()
    :ok = :erpc.call(peer_node, :global, :sync, [])

    {:ok, peer: peer, peer_node: peer_node}
  end

  defp start_endpoint_on(node, handler) do
    name = :"endpoint_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      :erpc.call(node, GenServer, :start, [Macrina.Endpoint, {handler, 0}, [name: name]])

    {:ok, socket} = :erpc.call(node, Macrina.Endpoint, :socket, [name])
    {:ok, {_, port}} = :erpc.call(node, :inet, :sockname, [socket])
    {pid, port}
  end

  defp open_client_socket do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false, reuseaddr: true])
    sock
  end

  defp send_block(socket, port, number, more, payload, token, id) do
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

    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, Message.encode(msg))
  end

  defp recv(socket) do
    {:ok, {_ip, _port, packet}} = :gen_udp.recv(socket, 0, 2_000)
    {:ok, msg} = Message.decode(packet)
    msg
  end

  test "block 0 to local node, block 1 to peer node assembles via shared :global BlockTransfer",
       %{peer_node: peer_node} do
    name = :"endpoint_local_#{System.unique_integer([:positive])}"
    {:ok, n1_pid} = Macrina.Endpoint.start_link(handler: EchoHandler, port: 0, name: name)
    {:ok, n1_socket} = Macrina.Endpoint.socket(n1_pid)
    {:ok, {_, n1_port}} = :inet.sockname(n1_socket)
    on_exit(fn -> if Process.alive?(n1_pid), do: GenServer.stop(n1_pid) end)

    {_n2_pid, n2_port} = start_endpoint_on(peer_node, EchoHandler)

    token = :crypto.strong_rand_bytes(8)
    socket = open_client_socket()
    on_exit(fn -> :gen_udp.close(socket) end)

    send_block(socket, n1_port, 0, true, "aaaaaaaaaaaaaaaa", token, 1)
    ack0 = recv(socket)
    assert ack0.code == :continue

    transfer_pid = :global.whereis_name({Macrina.BlockTransfer, {127, 0, 0, 1}, token})
    assert is_pid(transfer_pid)
    assert node(transfer_pid) == Node.self()

    send_block(socket, n2_port, 1, false, "bbbb", token, 2)
    final = recv(socket)
    assert final.code == :changed
    assert final.payload == "ok"
  end
end
