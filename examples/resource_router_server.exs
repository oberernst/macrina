defmodule Examples.ResourceRouter do
  @behaviour Macrina.Router

  alias Macrina.{Request, Resource, Response, Router}

  defp resources do
    [
      Resource.new!("/temperature",
        attributes: [rt: "temperature-c", ct: [0, 50]],
        get: [
          text_plain: Response.new(:content, payload: "22.3 C"),
          application_json: fn _request, _context ->
            Response.new(:content, payload: ~s({"value":"22.3 C"}))
          end
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
      )
    ]
  end

  @impl true
  def call(%Request{} = request, context) do
    Router.dispatch(resources(), request, context)
  end

  @impl true
  def discover(_request, _context) do
    Router.discovery_resources!(resources())
  end
end

port = String.to_integer(System.get_env("MACRINA_PORT") || "5683")

{:ok, server} = Macrina.Server.start_link(router: Examples.ResourceRouter, port: port)
{:ok, socket} = Macrina.Transport.UDP.socket(server)
{:ok, {_ip, bound_port}} = :inet.sockname(socket)

IO.puts("Macrina resource router listening on coap://127.0.0.1:#{bound_port}")
IO.puts("Try GET /temperature or /.well-known/core")
Process.sleep(:infinity)
