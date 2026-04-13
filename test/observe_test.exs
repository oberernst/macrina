defmodule Macrina.ObserveTest do
  use ExUnit.Case, async: false

  alias Macrina.{
    Client,
    Endpoint,
    Message,
    Message.Opts.Block,
    Observe,
    Request,
    Response,
    Server
  }

  defmodule ClientEndpointHandler do
    def call(_connection, _message) do
      nil
    end
  end

  defmodule ObserveHandler do
    def call(_connection, message) do
      Message.response!(message, code: :content, payload: "initial", type: :ack)
    end
  end

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end

  defp stop_process(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  end

  test "observe registry sequences notifications and cancels subscriptions" do
    endpoint = self()
    connection = self()
    token = <<1, 2, 3, 4>>

    assert {:ok, 0} = Observe.register(endpoint, connection, "/sensors/temp", token)

    assert {:ok, [%{observe: 1, path: ["sensors", "temp"], token: ^token}]} =
             Observe.notifications(endpoint, "/sensors/temp")

    assert {:ok, [%{observe: 2, path: ["sensors", "temp"], token: ^token}]} =
             Observe.notifications(endpoint, ["sensors", "temp"])

    assert :ok = Observe.cancel(endpoint, connection, token)
    assert {:ok, []} = Observe.notifications(endpoint, "/sensors/temp")
  end

  test "client observe receives notifications, emits telemetry, and cancels" do
    handler_id = "observe-public-api-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:macrina, :observe, :register],
          [:macrina, :observe, :notify],
          [:macrina, :observe, :cancel]
        ],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, server} = Server.start_link(handler: ObserveHandler, port: 0)
    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)

    endpoint_name = {:global, {:observe_test_endpoint, make_ref()}}

    {:ok, endpoint} =
      Endpoint.start_link(handler: ClientEndpointHandler, port: 0, name: endpoint_name)

    {:ok, endpoint_socket} = Endpoint.socket(endpoint_name)

    on_exit(fn ->
      stop_process(endpoint)
      :gen_udp.close(endpoint_socket)
      stop_process(server)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    request = Request.from_uri!(:get, "/temperature")

    assert {:ok, subscription, response} = Client.observe(client, request, notify_to: self())
    assert response.payload == "initial"
    assert Response.observe(response) == 0
    assert subscription.path == ["temperature"]

    assert_receive {[:macrina, :observe, :register], %{count: 1}, register_metadata}
    assert register_metadata.path == ["temperature"]
    assert register_metadata.token == subscription.token

    assert {:ok, 1} =
             Server.notify(server, "/temperature", Response.new(:content, payload: "next"))

    assert_receive {:macrina_observe, ^subscription, notification}
    assert notification.payload == "next"
    assert notification.type == :non
    assert Response.observe(notification) == 1

    assert_receive {[:macrina, :observe, :notify], %{count: 1, bytes: _}, notify_metadata}
    assert notify_metadata.observe == 1
    assert notify_metadata.path == ["temperature"]
    assert notify_metadata.token == subscription.token

    assert {:ok, cancel_response} = Client.cancel_observe(subscription)
    assert cancel_response.code == :content
    assert Response.observe(cancel_response) == nil

    assert_receive {[:macrina, :observe, :cancel], %{count: 1}, cancel_metadata}
    assert cancel_metadata.path == ["temperature"]
    assert cancel_metadata.token == subscription.token

    assert {:ok, 0} =
             Server.notify(server, "/temperature", Response.new(:content, payload: "ignored"))

    refute_receive {:macrina_observe, ^subscription, _response}, 100
  end

  test "client observe reassembles block2 notifications" do
    payload = "abcdefghijklmnopQRST"
    test_pid = self()

    {:ok, server_socket} = :gen_udp.open(0, [:binary, {:active, true}])
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)

    server =
      spawn_link(fn ->
        observe_block2_server_loop(server_socket, test_pid, %{
          client: nil,
          notification: nil,
          observe: 1
        })
      end)

    :ok = :gen_udp.controlling_process(server_socket, server)

    endpoint_name = {:global, {:observe_block2_endpoint, make_ref()}}

    {:ok, endpoint} =
      Endpoint.start_link(handler: ClientEndpointHandler, port: 0, name: endpoint_name)

    {:ok, endpoint_socket} = Endpoint.socket(endpoint_name)

    on_exit(fn ->
      stop_process(server)
      stop_process(endpoint)
      :gen_udp.close(endpoint_socket)
      :gen_udp.close(server_socket)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    request = Request.from_uri!(:get, "/stream")

    assert {:ok, subscription, response} = Client.observe(client, request, notify_to: self())
    assert response.payload == "initial"
    assert Response.observe(response) == 0

    send(server, {:notify, payload})

    assert_receive {:server_request, :initial_observe}
    assert_receive {:server_request, {:notification_block_request, 1}}

    assert_receive {:macrina_observe, ^subscription, notification}, 1_000
    assert notification.payload == payload
    assert Response.observe(notification) == 1
    assert Response.block2(notification) == %Block{number: 1, more: false, size: 16}
  end

  defp observe_block2_server_loop(socket, test_pid, state) do
    receive do
      {:udp, ^socket, ip, port, packet} ->
        {:ok, message} = Message.decode(packet)
        {:ok, request} = Request.from_message(message)

        next_state =
          cond do
            Request.observe(request) == 0 ->
              send(test_pid, {:server_request, :initial_observe})

              response =
                Message.response!(message,
                  code: :content,
                  payload: "initial",
                  options: [{"Observe", 0}],
                  type: :ack
                )

              {:ok, encoded_response} = Message.encode(response)
              :ok = :gen_udp.send(socket, ip, port, encoded_response)
              %{state | client: {ip, port, message.token}}

            match?(%Block{}, Request.block2(request)) ->
              block_number = Request.block2(request).number
              send(test_pid, {:server_request, {:notification_block_request, block_number}})

              response =
                notification_block_response(
                  state.notification,
                  state.observe,
                  block_number,
                  message.token,
                  710 + block_number
                )

              {:ok, encoded_response} = Message.encode(response)
              :ok = :gen_udp.send(socket, ip, port, encoded_response)

              if Response.block2(Response.from_message(response)).more do
                state
              else
                %{state | notification: nil, observe: state.observe + 1}
              end

            true ->
              state
          end

        observe_block2_server_loop(socket, test_pid, next_state)

      {:notify, payload} ->
        {ip, port, token} = state.client
        response = notification_block_response(payload, state.observe, 0, token, 700)
        {:ok, encoded_response} = Message.encode(response)
        :ok = :gen_udp.send(socket, ip, port, encoded_response)

        observe_block2_server_loop(socket, test_pid, %{state | notification: payload})
    end
  end

  defp notification_block_response(payload, observe, block_number, token, id) do
    block_size = 16
    offset = block_number * block_size
    remaining = byte_size(payload) - offset
    chunk_size = min(block_size, remaining)
    chunk = :binary.part(payload, offset, chunk_size)
    more = remaining > block_size

    Message.build!(:content,
      id: id,
      options: [
        {"Observe", observe},
        {"Block2", %Block{number: block_number, more: more, size: block_size}},
        {"Content-Format", 0}
      ],
      payload: chunk,
      token: token,
      type: :non
    )
  end
end
