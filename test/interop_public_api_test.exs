defmodule Macrina.InteropPublicApiTest do
  use ExUnit.Case, async: false

  alias Macrina.{Client, Endpoint, Request, Response, Router, Server}

  defmodule ClientEndpointRouter do
    @behaviour Router

    @impl true
    def call(_request, _context), do: nil
  end

  defmodule DemoRouter do
    @behaviour Router

    @impl true
    def call(%Request{method: :get, path: ["hello"]}, _context) do
      Response.new(:content, payload: "world", content_format: :text_plain)
    end

    def call(%Request{method: :get, path: ["temperature"]}, _context) do
      Response.new(:content, payload: "22.3 C", content_format: :text_plain)
    end

    def call(_request, _context) do
      Response.new(:not_found)
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    end

    :ok
  end

  defp start_server_and_client do
    {:ok, server} = Server.start_link(router: DemoRouter, port: 0)
    {:ok, server_socket} = Endpoint.socket(server)
    {:ok, {_ip, server_port}} = :inet.sockname(server_socket)

    endpoint_name = {:global, {:interop_client_endpoint, make_ref()}}

    {:ok, endpoint} =
      Endpoint.start_link(router: ClientEndpointRouter, port: 0, name: endpoint_name)

    {:ok, client} = Client.connect(ip: {127, 0, 0, 1}, port: server_port, endpoint: endpoint_name)

    on_exit(fn ->
      stop_process(client.conn)
      stop_process(endpoint)
      stop_process(server)
    end)

    {server, client}
  end

  test "public server and client APIs interoperate for basic requests" do
    {_server, client} = start_server_and_client()

    assert {:ok, response} = Client.get(client, "/hello")
    assert response.code == :content
    assert response.payload == "world"
    assert Response.content_format(response) == :text_plain
  end

  test "public observe API delivers notifications end to end" do
    {server, client} = start_server_and_client()

    request = Request.from_uri!(:get, "/temperature")

    assert {:ok, subscription, initial_response} =
             Client.observe(client, request, notify_to: self())

    assert initial_response.code == :content
    assert initial_response.payload == "22.3 C"
    assert Response.observe(initial_response) == 0

    assert {:ok, 1} =
             Server.notify(
               server,
               "/temperature",
               Response.new(:content, payload: "23.1 C", content_format: :text_plain)
             )

    assert_receive {:macrina_observe, ^subscription, notification}, 1_000
    assert notification.code == :content
    assert notification.payload == "23.1 C"
    assert notification.type == :non
    assert Response.observe(notification) == 1
  end
end
