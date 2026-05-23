defmodule Macrina.Transport.UDPTest do
  use ExUnit.Case, async: false

  alias Macrina.Transport.UDP

  describe "behaviour conformance" do
    test "implements Macrina.Transport" do
      assert function_exported?(UDP, :open, 1)
      assert function_exported?(UDP, :send, 3)
      assert function_exported?(UDP, :close, 1)
    end
  end

  describe "open/1 and close/1" do
    test "opens a UDP socket on an ephemeral port and closes it" do
      assert {:ok, socket} = UDP.open(port: 0)
      assert {:ok, {_ip, port}} = :inet.sockname(socket)
      assert is_integer(port) and port > 0
      assert :ok = UDP.close(socket)
    end

    test "honors :active true and delivers received packets to the controlling process" do
      {:ok, recv_socket} = UDP.open(port: 0, active: true)
      {:ok, {_ip, recv_port}} = :inet.sockname(recv_socket)

      {:ok, send_socket} = UDP.open(port: 0, active: false)

      :ok = UDP.send(send_socket, {{127, 0, 0, 1}, recv_port}, "ping")

      assert_receive {:udp, ^recv_socket, _ip, _port, "ping"}, 200

      :ok = UDP.close(recv_socket)
      :ok = UDP.close(send_socket)
    end
  end

  describe "send/3" do
    test "delivers a binary to {ip, port}" do
      {:ok, recv_socket} = UDP.open(port: 0, active: false)
      {:ok, {_ip, recv_port}} = :inet.sockname(recv_socket)
      {:ok, send_socket} = UDP.open(port: 0, active: false)

      :ok = UDP.send(send_socket, {{127, 0, 0, 1}, recv_port}, "hello")

      assert {:ok, {_, _, "hello"}} = :gen_udp.recv(recv_socket, 0, 200)

      :ok = UDP.close(recv_socket)
      :ok = UDP.close(send_socket)
    end
  end
end
