# Getting Started

This guide shows the smallest complete Macrina setup: one server, one client,
and a single request/response round trip using only the public API.

## 1. Add the dependency

```elixir
defp deps do
  [
    {:macrina, "~> 0.1.4"}
  ]
end
```

## 2. Start a server

```elixir
defmodule MyApp.Router do
  @behaviour Macrina.Router

  alias Macrina.{Request, Response}

  @impl true
  def call(%Request{method: :get, path: ["hello"]}, _context) do
    Response.new(:content, payload: "hello", content_format: :text_plain)
  end

  def call(_request, _context) do
    Response.new(:not_found)
  end
end

{:ok, server} = Macrina.Server.start_link(router: MyApp.Router, port: 5683)
```

## 3. Connect a client

```elixir
{:ok, client} = Macrina.Client.connect(ip: {127, 0, 0, 1}, port: 5683)
```

## 4. Send a request

```elixir
{:ok, response} = Macrina.Client.get(client, "/hello")

response.code
# => :content

response.payload
# => "hello"
```

## 5. Build requests explicitly when needed

```elixir
request =
  Macrina.Request.from_uri!(:get, "coap://127.0.0.1:5683/hello",
    accept: :text_plain,
    type: :con
  )

{:ok, response} = Macrina.Client.request(client, request)
```

## 6. Shut down cleanly

`Macrina.Server.start_link/1` returns the endpoint pid, so you can stop it with
standard OTP tools:

```elixir
GenServer.stop(server)
```

## Next steps

- See `examples/basic_server.exs` and `examples/basic_client.exs` for runnable scripts.
- Read `docs/guides/routing-and-discovery.md` for structured routing.
- Read `docs/guides/observe-and-blockwise.md` for server push and large payloads.