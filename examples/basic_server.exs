defmodule Examples.BasicServer.Router do
  @behaviour Macrina.Router

  alias Macrina.{Request, Response}

  @impl true
  def call(%Request{method: :get, path: ["hello"]}, _context) do
    Response.new(:content, payload: "hello from macrina", content_format: :text_plain)
  end

  def call(_request, _context) do
    Response.new(:not_found)
  end
end

port = String.to_integer(System.get_env("MACRINA_PORT") || "5683")

{:ok, server} = Macrina.Server.start_link(router: Examples.BasicServer.Router, port: port)
{:ok, socket} = Macrina.Transport.UDP.socket(server)
{:ok, {_ip, bound_port}} = :inet.sockname(socket)

IO.puts("Macrina example server listening on coap://127.0.0.1:#{bound_port}/hello")
Process.sleep(:infinity)
