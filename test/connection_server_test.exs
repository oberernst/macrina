defmodule Macrina.ConnectionServerTest do
  use ExUnit.Case, async: false

  alias Macrina.{Connection.Server, Message}

  defmodule TestHandler do
    def call(_connection, _message), do: nil
  end

  test "start_link returns a missing option error" do
    assert {:error, {:missing_option, :handler}} = Server.start_link([])
  end

  test "start_link returns a running server when required options are present" do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
    name = {:global, {Server, make_ref()}}

    assert {:ok, pid} =
             Server.start_link(
               handler: TestHandler,
               ip: {127, 0, 0, 1},
               port: 5683,
               socket: socket,
               name: name
             )

    assert Process.alive?(pid)

    GenServer.stop(pid)
    :gen_udp.close(socket)
  end

  test "call returns an encode error when the outbound request is invalid" do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
    name = {:global, {Server, make_ref()}}

    assert {:ok, pid} =
             Server.start_link(
               handler: TestHandler,
               ip: {127, 0, 0, 1},
               port: 5683,
               socket: socket,
               name: name
             )

    message = Message.build(:get, id: 1, token: <<1, 2, 3, 4, 5, 6, 7, 8, 9>>, type: :con)

    assert Server.call(pid, message) == {:error, {:encode_failed, :invalid_token_length}}

    GenServer.stop(pid)
    :gen_udp.close(socket)
  end
end
