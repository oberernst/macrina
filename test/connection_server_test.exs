defmodule Macrina.ConnectionServerTest do
  use ExUnit.Case, async: false

  alias Macrina.{Connection.Server, Message}

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  defmodule TestHandler do
    def call(_connection, _message) do
      nil
    end
  end

  test "start_link returns a missing option error" do
    assert {:error, {:missing_option, :handler}} = Server.start_link([])
  end

  test "start_link returns a running server when required options are present" do
    handler_id = "connection-server-start-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:macrina, :connection, :start], [:macrina, :connection, :stop]],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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

    assert_receive {[:macrina, :connection, :start], %{system_time: _},
                    %{ip: {127, 0, 0, 1}, peer: _, port: 5683}}

    GenServer.stop(pid)

    assert_receive {[:macrina, :connection, :stop], %{system_time: _},
                    %{ip: {127, 0, 0, 1}, peer: _, port: 5683}}

    :gen_udp.close(socket)
  end

  test "call returns an encode error when the outbound request is invalid" do
    handler_id = "connection-server-encode-error-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:macrina, :connection, :request, :encode, :error],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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

    message = Message.build!(:get, id: 1, token: <<1, 2, 3, 4>>, type: :con)
    bad_message = %Message{message | token: <<1, 2, 3, 4, 5, 6, 7, 8, 9>>}

    assert Server.call(pid, bad_message) == {:error, {:encode_failed, :invalid_token_length}}

    assert_receive {[:macrina, :connection, :request, :encode, :error], %{count: 1},
                    %{error: :invalid_token_length, ip: {127, 0, 0, 1}, peer: _, port: 5683}}

    GenServer.stop(pid)
    :gen_udp.close(socket)
  end
end
