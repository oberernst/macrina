defmodule Macrina.Peer.SessionTest do
  use ExUnit.Case, async: false

  alias Macrina.{Block1.Chunk, Message, Message.Opts.Block, Peer.Session, Response}

  defmodule CountingRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      Agent.update(__MODULE__, &(&1 + 1))
      Response.new(:content, payload: "ok")
    end
  end

  defmodule NilCountingRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context) do
      Agent.update(__MODULE__, &(&1 + 1))
      nil
    end
  end

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  defmodule TestRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context), do: nil
  end

  defmodule StreamingRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context), do: nil

    @impl true
    def block1(%Chunk{} = chunk, _context) do
      pid = :persistent_term.get({__MODULE__, :test_pid})
      send(pid, {:stream_chunk, chunk.complete, chunk.bytes, chunk.message.payload})

      if chunk.complete do
        Response.new(:changed)
      end
    end
  end

  test "start_link returns a missing option error" do
    assert {:error, {:missing_option, :router}} = Session.start_link([])
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
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               router: TestRouter,
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
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               router: TestRouter,
               ip: {127, 0, 0, 1},
               port: 5683,
               socket: socket,
               name: name
             )

    message = Message.build!(:get, id: 1, token: <<1, 2, 3, 4>>, type: :con)
    bad_message = %Message{message | token: <<1, 2, 3, 4, 5, 6, 7, 8, 9>>}

    assert Session.call(pid, bad_message) == {:error, {:encode_failed, :invalid_token_length}}

    assert_receive {[:macrina, :connection, :request, :encode, :error], %{count: 1},
                    %{error: :invalid_token_length, ip: {127, 0, 0, 1}, peer: _, port: 5683}}

    GenServer.stop(pid)
    :gen_udp.close(socket)
  end

  test "duplicate confirmable requests reuse the cached reply" do
    handler_id = "connection-server-dedup-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:macrina, :exchange, :dedup, :hit],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, counter} = Agent.start_link(fn -> 0 end, name: CountingRouter)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)

    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               router: CountingRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 333, token: <<1, 2, 3, 4>>, type: :con)
    {:ok, packet} = Message.encode(request)

    send(pid, {:coap, packet})
    send(pid, {:coap, packet})

    assert {:ok, {_ip, _port, first_reply}} = :gen_udp.recv(recv_socket, 0, 1000)
    assert {:ok, {_ip, _port, second_reply}} = :gen_udp.recv(recv_socket, 0, 1000)
    assert first_reply == second_reply

    assert {:ok, reply_message} = Message.decode(first_reply)
    assert reply_message.code == :content
    assert reply_message.payload == "ok"
    assert reply_message.type == :ack

    assert Agent.get(CountingRouter, & &1) == 1

    assert_receive {[:macrina, :exchange, :dedup, :hit], %{count: 1},
                    %{cached: true, code: :get, id: 333, ip: {127, 0, 0, 1}, peer: _, port: _}}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "duplicate confirmable requests with no reply do not rerun the handler" do
    handler_id = "connection-server-dedup-nil-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:macrina, :exchange, :dedup, :hit],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, counter} = Agent.start_link(fn -> 0 end, name: NilCountingRouter)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               router: NilCountingRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 335, token: <<1, 2, 3, 6>>, type: :con)
    {:ok, packet} = Message.encode(request)

    send(pid, {:coap, packet})
    send(pid, {:coap, packet})

    assert {:error, :timeout} = :gen_udp.recv(recv_socket, 0, 80)
    assert Agent.get(NilCountingRouter, & &1) == 1

    assert_receive {[:macrina, :exchange, :dedup, :hit], %{count: 1},
                    %{cached: false, code: :get, id: 335, ip: {127, 0, 0, 1}, peer: _, port: _}}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "duplicate confirmable requests after exchange lifetime are treated as new" do
    {:ok, counter} = Agent.start_link(fn -> 0 end, name: CountingRouter)

    on_exit(fn ->
      if Process.alive?(counter) do
        Agent.stop(counter)
      end
    end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               exchange_lifetime: 30,
               router: CountingRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 334, token: <<1, 2, 3, 5>>, type: :con)
    {:ok, packet} = Message.encode(request)

    send(pid, {:coap, packet})
    assert {:ok, {_ip, _port, _first_reply}} = :gen_udp.recv(recv_socket, 0, 200)

    Process.sleep(40)

    send(pid, {:coap, packet})
    assert {:ok, {_ip, _port, _second_reply}} = :gen_udp.recv(recv_socket, 0, 200)

    assert Agent.get(CountingRouter, & &1) == 2

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "confirmable requests retransmit and time out" do
    handler_id = "connection-server-retransmit-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:macrina, :exchange, :retransmit], [:macrina, :exchange, :timeout]],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               ack_timeout: 20,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               max_retransmit: 2,
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 401, token: <<4, 0, 1, 0>>, type: :con)
    task = Task.async(fn -> Session.call(pid, request, 1_000) end)

    assert {:ok, {_ip, _port, first_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, {_ip, _port, second_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, {_ip, _port, third_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    assert first_packet == second_packet
    assert first_packet == third_packet
    assert Task.await(task) == {:error, :ack_timeout}

    assert_receive {[:macrina, :exchange, :retransmit], %{attempt: 1, bytes: _, count: 1},
                    %{
                      id: 401,
                      ip: {127, 0, 0, 1},
                      peer: _,
                      port: ^recv_port,
                      token: <<4, 0, 1, 0>>
                    }}

    assert_receive {[:macrina, :exchange, :retransmit], %{attempt: 2, bytes: _, count: 1},
                    %{
                      id: 401,
                      ip: {127, 0, 0, 1},
                      peer: _,
                      port: ^recv_port,
                      token: <<4, 0, 1, 0>>
                    }}

    assert_receive {[:macrina, :exchange, :timeout], %{count: 1, retransmissions: 2},
                    %{
                      id: 401,
                      ip: {127, 0, 0, 1},
                      peer: _,
                      port: ^recv_port,
                      token: <<4, 0, 1, 0>>
                    }}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "empty ack stops retransmission and separate responses complete the request" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               ack_timeout: 100,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               max_retransmit: 2,
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 402, token: <<4, 0, 2, 0>>, type: :con)
    task = Task.async(fn -> Session.call(pid, request, 1_000) end)

    assert {:ok, {_ip, _port, _first_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    empty_ack = Message.build!(:empty, id: request.id, type: :ack)
    {:ok, empty_ack_packet} = Message.encode(empty_ack)
    send(pid, {:coap, empty_ack_packet})

    assert {:error, :timeout} = :gen_udp.recv(recv_socket, 0, 60)

    response = Message.build!(:content, id: 999, payload: "ok", token: request.token, type: :con)
    {:ok, response_packet} = Message.encode(response)
    send(pid, {:coap, response_packet})

    assert {:ok, {_ip, _port, ack_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, ack_message} = Message.decode(ack_packet)
    assert ack_message.code == :empty
    assert ack_message.id == 999
    assert ack_message.type == :ack

    assert {:ok, reply_message} = Task.await(task)
    assert reply_message.code == :content
    assert reply_message.payload == "ok"
    assert reply_message.type == :con

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "piggybacked ack responses complete the request without retransmission" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               ack_timeout: 100,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               max_retransmit: 2,
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 405, token: <<4, 0, 5, 0>>, type: :con)
    task = Task.async(fn -> Session.call(pid, request, 1_000) end)

    assert {:ok, {_ip, _port, _first_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    response =
      Message.build!(:content, id: request.id, payload: "ok", token: request.token, type: :ack)

    {:ok, response_packet} = Message.encode(response)
    send(pid, {:coap, response_packet})

    assert {:error, :timeout} = :gen_udp.recv(recv_socket, 0, 60)

    assert {:ok, reply_message} = Task.await(task)
    assert reply_message.code == :content
    assert reply_message.id == request.id
    assert reply_message.payload == "ok"
    assert reply_message.type == :ack

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "empty acked requests time out when no separate response arrives" do
    handler_id = "connection-server-separate-timeout-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:macrina, :exchange, :timeout],
        &__MODULE__.telemetry_handler/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               ack_timeout: 100,
               exchange_lifetime: 50,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               max_retransmit: 2,
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 404, token: <<4, 0, 4, 0>>, type: :con)
    task = Task.async(fn -> Session.call(pid, request, 1_000) end)

    assert {:ok, {_ip, _port, _first_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    empty_ack = Message.build!(:empty, id: request.id, type: :ack)
    {:ok, empty_ack_packet} = Message.encode(empty_ack)
    send(pid, {:coap, empty_ack_packet})

    assert {:error, :timeout} = :gen_udp.recv(recv_socket, 0, 80)
    assert Task.await(task) == {:error, :response_timeout}

    assert_receive {[:macrina, :exchange, :timeout], %{count: 1, retransmissions: 0},
                    %{
                      id: 404,
                      ip: {127, 0, 0, 1},
                      peer: _,
                      phase: :awaiting_response,
                      port: ^recv_port,
                      token: <<4, 0, 4, 0>>
                    }}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "reset packets stop retransmission and fail the request" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               ack_timeout: 100,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               max_retransmit: 2,
               port: recv_port,
               socket: send_socket,
               name: name
             )

    request = Message.build!(:get, id: 403, token: <<4, 0, 3, 0>>, type: :con)
    task = Task.async(fn -> Session.call(pid, request, 1_000) end)

    assert {:ok, {_ip, _port, _first_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    reset = Message.build!(:empty, id: request.id, type: :rst)
    {:ok, reset_packet} = Message.encode(reset)
    send(pid, {:coap, reset_packet})

    assert {:error, :timeout} = :gen_udp.recv(recv_socket, 0, 60)
    assert Task.await(task) == {:error, :request_reset}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "block1 continue replies acknowledge the block and negotiate a preferred size" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               block1_preferred_block_size: 32,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    block = %Block{number: 0, more: true, size: 64}

    request =
      Message.build!(:put,
        id: 501,
        options: [{"Block1", block}, {"Content-Format", 0}],
        payload: String.duplicate("a", 64),
        token: <<5, 0, 1, 0>>,
        type: :con
      )

    {:ok, packet} = Message.encode(request)
    send(pid, {:coap, packet})

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)

    assert reply_message.code == :continue
    assert reply_message.type == :ack
    assert reply_message.control_block == %Block{number: 0, more: false, size: 32}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "oversized block1 uploads return request entity too large" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               block1_max_body_size: 64,
               router: TestRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    first_request =
      Message.build!(:put,
        id: 502,
        options: [{"Block1", %Block{number: 0, more: true, size: 64}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 64),
        token: <<5, 0, 2, 0>>,
        type: :con
      )

    second_request =
      Message.build!(:put,
        id: 503,
        options: [{"Block1", %Block{number: 1, more: false, size: 64}}, {"Content-Format", 0}],
        payload: "b",
        token: <<5, 0, 2, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    send(pid, {:coap, first_packet})

    assert {:ok, {_ip, _port, continue_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, continue_message} = Message.decode(continue_packet)
    assert continue_message.code == :continue

    {:ok, second_packet} = Message.encode(second_request)
    send(pid, {:coap, second_packet})

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)

    assert reply_message.code == :request_entity_too_large
    assert reply_message.type == :ack
    assert reply_message.control_block == %Block{number: 1, more: false, size: 64}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "out-of-sequence block1 uploads return request entity incomplete with block state" do
    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               router: TestRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    first_request =
      Message.build!(:put,
        id: 504,
        options: [{"Block1", %Block{number: 0, more: true, size: 32}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 32),
        token: <<5, 0, 4, 0>>,
        type: :con
      )

    skipped_request =
      Message.build!(:put,
        id: 505,
        options: [{"Block1", %Block{number: 2, more: false, size: 32}}, {"Content-Format", 0}],
        payload: String.duplicate("b", 8),
        token: <<5, 0, 4, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    send(pid, {:coap, first_packet})
    assert {:ok, {_ip, _port, _continue_packet}} = :gen_udp.recv(recv_socket, 0, 200)

    {:ok, skipped_packet} = Message.encode(skipped_request)
    send(pid, {:coap, skipped_packet})

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)

    assert reply_message.code == :request_entity_incomplete
    assert reply_message.type == :ack
    assert reply_message.control_block == %Block{number: 2, more: false, size: 32}

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end

  test "streaming block1 mode delivers chunks before upload completion" do
    :persistent_term.put({StreamingRouter, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({StreamingRouter, :test_pid})
    end)

    {:ok, send_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, recv_socket} = :gen_udp.open(0, [:binary, {:active, false}])
    {:ok, {_recv_ip, recv_port}} = :inet.sockname(recv_socket)
    name = {:global, {Session, make_ref()}}

    assert {:ok, pid} =
             Session.start_link(
               block1_mode: :streaming,
               router: StreamingRouter,
               ip: {127, 0, 0, 1},
               port: recv_port,
               socket: send_socket,
               name: name
             )

    first_request =
      Message.build!(:put,
        id: 506,
        options: [{"Block1", %Block{number: 0, more: true, size: 32}}, {"Content-Format", 0}],
        payload: String.duplicate("a", 32),
        token: <<5, 0, 6, 0>>,
        type: :con
      )

    second_request =
      Message.build!(:put,
        id: 507,
        options: [{"Block1", %Block{number: 1, more: false, size: 32}}, {"Content-Format", 0}],
        payload: "done",
        token: <<5, 0, 6, 0>>,
        type: :con
      )

    {:ok, first_packet} = Message.encode(first_request)
    send(pid, {:coap, first_packet})

    assert_receive {:stream_chunk, false, 32, first_payload}
    assert first_payload == String.duplicate("a", 32)

    assert {:ok, {_ip, _port, continue_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, continue_message} = Message.decode(continue_packet)
    assert continue_message.code == :continue

    {:ok, second_packet} = Message.encode(second_request)
    send(pid, {:coap, second_packet})

    assert_receive {:stream_chunk, true, 36, "done"}

    assert {:ok, {_ip, _port, reply_packet}} = :gen_udp.recv(recv_socket, 0, 200)
    assert {:ok, reply_message} = Message.decode(reply_packet)
    assert reply_message.code == :changed
    assert reply_message.type == :ack

    GenServer.stop(pid)
    :gen_udp.close(send_socket)
    :gen_udp.close(recv_socket)
  end
end
