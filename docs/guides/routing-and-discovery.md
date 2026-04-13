# Routing and Discovery

Macrina supports two routing styles:

- A plain router module with your own pattern matching.
- A data-driven resource table built from `Macrina.Resource` definitions.

## Plain router modules

```elixir
defmodule MyApp.Router do
  @behaviour Macrina.Router

  alias Macrina.{Request, Response}

  @impl true
  def call(%Request{method: :get, path: ["temperature"]}, _context) do
    Response.new(:content, payload: "22.3 C", content_format: :text_plain)
  end

  def call(_request, _context) do
    Response.new(:not_found)
  end
end
```

Use this when the routing table is small and hand-written pattern matching is
already the clearest representation.

## Data-driven resources

`Macrina.Resource` is a better fit when you want a single source of truth for:

- request dispatch
- path parameters
- content negotiation
- `/.well-known/core` discovery

```elixir
defmodule MyApp.Router do
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
```

## Path patterns

- `"/temperature"` matches a literal path.
- `"/devices/:device_id"` captures one segment into `context.path_params.device_id`.
- `"/files/*path"` captures the remaining tail into `context.path_params.path`.

If a resource has dynamic path segments and should appear in discovery output,
set a concrete `:discovery_path`. If it should not be published, set
`discoverable: false`.

## Discovery

When a router exports `discover/2`, Macrina answers GET requests for
`/.well-known/core` with `application/link-format`.

```elixir
@impl true
def discover(_request, _context) do
  [
    Macrina.Discovery.Resource.new!("/temperature", rt: "temperature-c", ct: [0])
  ]
end
```