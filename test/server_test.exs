defmodule Macrina.ServerTest do
  use ExUnit.Case, async: false

  alias Macrina.{
    Block1,
    Client,
    Endpoint,
    Message,
    Message.Opts.Block,
    Request,
    Resource,
    Response,
    Router,
    Server
  }

  defmodule NilRouter do
    @behaviour Macrina.Router

    @impl true
    def call(_request, _context), do: nil
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

  defmodule DiscoveryRouter do
    @behaviour Macrina.Router

    defp resources do
      [
        Resource.new!("/temperature",
          attributes: [rt: "temperature-c", ct: [0]],
          get: [
            text_plain: Response.new(:content, payload: "22.3 C"),
            application_json: fn _request, _context ->
              Response.new(:content, payload: "{\"value\":\"22.3 C\"}")
            end
          ]
        ),
        Resource.new!("/humidity",
          attributes: [rt: "humidity", ct: [50]],
          get: [
            application_json:
              Response.new(:content,
                payload: "{\"value\":54}"
              )
          ]
        ),
        Resource.new!("/devices/:device_id",
          discovery_path: "/devices",
          attributes: [rt: "device-id", ct: [0]],
          get: fn _request, context ->
            Response.new(:content,
              payload: Map.fetch!(context.path_params, :device_id),
              content_format: :text_plain
            )
          end
        ),
        Resource.new!("/files/*path",
          discovery_path: "/files",
          attributes: [rt: "file-collection", ct: [0]],
          get: fn _request, context ->
            payload = Enum.join(Map.fetch!(context.path_params, :path), "/")

            Response.new(:content,
              payload: payload,
              content_format: :text_plain
            )
          end
        )
      ]
    end

    @impl true
    def call(request, context) do
      Router.dispatch(resources(), request, context)
    end

    @impl true
    def discover(_request, _context) do
      Router.discovery_resources!(resources())
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    Process.exit(pid, :normal)
    :ok
  end

  test "public server propagates block1 preferred block size" do
    policy = Block1.new!(preferred_block_size: 32)

    assert {:ok, server} = Server.start_link(router: NilRouter, port: 0, block1: policy)

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      stop_process(server)
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
             Server.start_link(router: NilRouter, port: 0, block1: [max_body_size: 64])

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    {:ok, client_socket} = :gen_udp.open(0, [:binary, {:active, false}])

    on_exit(fn ->
      stop_process(server)
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
               router: NilRouter,
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
      stop_process(server)
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
             Server.start_link(router: NilRouter, port: 0, block1: [mode: :streaming])
  end

  test "public server serves multiple router resources and discovery" do
    assert {:ok, server} = Server.start_link(router: DiscoveryRouter, port: 0)

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    client_endpoint_name = {:global, {:server_test_client_endpoint, make_ref()}}

    assert {:ok, client_endpoint} =
             Endpoint.start_link(router: NilRouter, port: 0, name: client_endpoint_name)

    on_exit(fn ->
      stop_process(client_endpoint)
      stop_process(server)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: client_endpoint_name)

    assert {:ok, temperature_response} = Client.get(client, "/temperature")
    assert temperature_response.code == :content
    assert temperature_response.payload == "22.3 C"
    assert Response.content_format(temperature_response) == :text_plain

    request = Request.from_uri!(:get, "/temperature", accept: :application_json)

    assert {:ok, json_temperature_response} = Client.request(client, request)
    assert json_temperature_response.code == :content
    assert json_temperature_response.payload == "{\"value\":\"22.3 C\"}"
    assert Response.content_format(json_temperature_response) == :application_json

    assert {:ok, humidity_response} = Client.get(client, "/humidity")
    assert humidity_response.code == :content
    assert humidity_response.payload == "{\"value\":54}"
    assert Response.content_format(humidity_response) == :application_json

    assert {:ok, device_response} = Client.get(client, "/devices/alpha")
    assert device_response.code == :content
    assert device_response.payload == "alpha"
    assert Response.content_format(device_response) == :text_plain

    assert {:ok, files_response} = Client.get(client, "/files/archive/2026/report.txt")
    assert files_response.code == :content
    assert files_response.payload == "archive/2026/report.txt"
    assert Response.content_format(files_response) == :text_plain

    assert {:ok, discovery_response} = Client.get(client, "/.well-known/core")
    assert discovery_response.code == :content
    assert Response.content_format(discovery_response) == :application_link_format

    assert discovery_response.payload ==
             "</temperature>;rt=\"temperature-c\";ct=\"0\",</humidity>;rt=\"humidity\";ct=\"50\",</devices>;rt=\"device-id\";ct=\"0\",</files>;rt=\"file-collection\";ct=\"0\""
  end

  test "public server returns not acceptable for discovery requests with another accept format" do
    assert {:ok, server} = Server.start_link(router: DiscoveryRouter, port: 0)

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    client_endpoint_name = {:global, {:server_test_client_endpoint, make_ref()}}

    assert {:ok, client_endpoint} =
             Endpoint.start_link(router: NilRouter, port: 0, name: client_endpoint_name)

    on_exit(fn ->
      stop_process(client_endpoint)
      stop_process(server)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: client_endpoint_name)

    request = Request.from_uri!(:get, "/.well-known/core", accept: :application_json)

    assert {:ok, response} = Client.request(client, request)
    assert response.code == :not_acceptable
    assert Response.content_format(response) == nil
  end

  test "public server returns not acceptable when a routed resource cannot satisfy accept" do
    assert {:ok, server} = Server.start_link(router: DiscoveryRouter, port: 0)

    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)
    client_endpoint_name = {:global, {:server_test_client_endpoint, make_ref()}}

    assert {:ok, client_endpoint} =
             Endpoint.start_link(router: NilRouter, port: 0, name: client_endpoint_name)

    on_exit(fn ->
      stop_process(client_endpoint)
      stop_process(server)
    end)

    assert {:ok, client} =
             Client.new(ip: {127, 0, 0, 1}, port: server_port, endpoint: client_endpoint_name)

    request = Request.from_uri!(:get, "/humidity", accept: :text_plain)

    assert {:ok, response} = Client.request(client, request)
    assert response.code == :not_acceptable
    assert Response.content_format(response) == nil
  end
end
