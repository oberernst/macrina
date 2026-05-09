# Macrina

An Elixir CoAP client and server library.

Macrina implements the [Constrained Application Protocol](https://datatracker.ietf.org/doc/html/rfc7252) (CoAP, RFC 7252) for machine-to-machine communication over UDP, with support for:

- Confirmable and non-confirmable messages with automatic retransmission
- Block1 (upload) and Block2 (download) transfers ([RFC 7959](https://datatracker.ietf.org/doc/html/rfc7959))
- Observe subscriptions and server-push notifications ([RFC 7641](https://datatracker.ietf.org/doc/html/rfc7641))
- CoRE Link Format discovery via `/.well-known/core` ([RFC 6690](https://datatracker.ietf.org/doc/html/rfc6690))
- Per-resource content negotiation and path-parameter routing
- `:telemetry` instrumentation across the full request lifecycle

---

## Installation

Add `macrina` to your dependencies in `mix.exs`:

```elixir
defp deps do
  [
    {:macrina, "~> 0.1.4"}
  ]
end
```

## Guides

- [Getting Started](docs/guides/getting-started.md)
- [Routing and Discovery](docs/guides/routing-and-discovery.md)
- [Observe and Blockwise Transfers](docs/guides/observe-and-blockwise.md)
- [Support Matrix](docs/support-matrix.md)
- [Known Limitations](docs/known-limitations.md)
- [Contributing](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)

## Quick Start

### Server

```elixir
defmodule MyApp.Handler do
  def call(_connection, message) do
    Macrina.Message.response!(message, code: :content, payload: "hello", type: :ack)
  end
end

{:ok, _server} = Macrina.Server.start_link(handler: MyApp.Handler, port: 5683)
```

### Client

```elixir
{:ok, client} = Macrina.Client.connect(ip: {127, 0, 0, 1}, port: 5683)

{:ok, response} = Macrina.Client.get(client, "/hello")
response.payload
# => "hello"
```

## Routing

For applications with multiple resources, implement the `Macrina.Router` behaviour:

```elixir
defmodule MyApp.Router do
  @behaviour Macrina.Router

  @impl true
  def call(request, _context) do
    case {request.method, request.path} do
      {:get, ["temperature"]} ->
        Macrina.Response.new(:content, payload: "22.3 C", content_format: :text_plain)

      _ ->
        Macrina.Response.new(:not_found)
    end
  end
end

{:ok, _server} = Macrina.Server.start_link(router: MyApp.Router, port: 5683)
```

### Data-Driven Routing

For richer dispatch with path parameters, content negotiation, and automatic
discovery, define `Macrina.Resource` entries:

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

## Observe

Servers can push notifications to clients observing a resource:

```elixir
# Client side
{:ok, client} = Macrina.Client.connect(ip: {127, 0, 0, 1}, port: 5683)
request = Macrina.Request.from_uri!(:get, "/temperature")

{:ok, subscription, initial} =
  Macrina.Client.observe(client, request, notify_to: self())

receive do
  {:macrina_observe, ^subscription, notification} ->
    notification.payload
end

:ok = Macrina.Client.cancel_observe(subscription)
```

```elixir
# Server side
{:ok, count} = Macrina.Server.notify(server, "/temperature",
  Macrina.Response.new(:content, payload: "23.1 C")
)
```

## Block Transfers

### Block2 (Download)

The client automatically reassembles block2 responses. No special configuration
is needed.

### Block1 (Upload)

Configure upload policy when starting the server:

```elixir
block1 = Macrina.Block1.new!(
  max_body_size: 64 * 1024,
  mode: :streaming,
  preferred_block_size: 512
)

{:ok, _server} = Macrina.Server.start_link(
  router: MyApp.Router,
  port: 5683,
  block1: block1
)
```

In `:atomic` mode (the default), handlers receive the fully reassembled payload.
In `:streaming` mode, handlers receive `Macrina.Block1.Chunk` values as blocks
arrive, and routers can implement `block1/2` to process them incrementally.

## Discovery

Routers that implement `discover/2` automatically serve `/.well-known/core`
with `application/link-format` responses:

```elixir
@impl true
def discover(_request, _context) do
  [
    Macrina.Discovery.Resource.new!("/temperature", rt: "temperature-c", ct: [0])
  ]
end
```

## Request & Response Helpers

Both `Macrina.Request` and `Macrina.Response` provide typed accessors for
common CoAP options:

```elixir
request = Macrina.Request.new(:get, accept: :application_json, observe: 0)
Macrina.Request.accept(request)   # => :application_json

response = Macrina.Response.new(:content,
  content_format: :text_plain,
  max_age: 60,
  location_path: ["devices", "alpha"]
)
Macrina.Response.content_format(response)  # => :text_plain
Macrina.Response.location_path(response)   # => ["devices", "alpha"]
```

## Architecture

```text
Macrina.Server / Macrina.Client
      │
Macrina.Transport.UDP          ← UDP socket (GenServer over :gen_udp)
      │
Macrina.Peer.Session ← per-peer GenServer (CON/NON/ACK/RST)
      │
Macrina.Handler           ← dispatches to raw modules or Routers
```

Each incoming UDP peer spawns a `Macrina.Peer.Session` under a
`DynamicSupervisor`. Pure protocol state (tokens, message IDs, block transfers,
retransmission tracking) lives in `Macrina.Exchange`. Connections idle-timeout
after five minutes of inactivity.

Key internal modules:

| Module | Role |
| --- | --- |
| `Macrina.Message` | Binary CoAP codec (encode/decode) |
| `Macrina.Exchange` | Pure exchange state machine |
| `Macrina.Peer.State` | Per-peer state struct |
| `Macrina.Blockwise` | Block transfer assembly |
| `Macrina.Observe` | Server-side observe registry |
| `Macrina.Telemetry` | `:telemetry` event wrapper |

## Telemetry

All events are prefixed with `[:macrina]`. Key events:

| Event | Measurements | Description |
| --- | --- | --- |
| `[:macrina, :connection, :start]` | `system_time` | Peer connection opened |
| `[:macrina, :connection, :stop]` | `system_time` | Peer connection closed |
| `[:macrina, :connection, :reply, :sent]` | `bytes` | Reply sent to peer |
| `[:macrina, :client, :request]` | span | Client request round-trip |
| `[:macrina, :exchange, :retransmit]` | `attempt`, `bytes` | CON retransmission |
| `[:macrina, :exchange, :timeout]` | `retransmissions` | Request timed out |
| `[:macrina, :observe, :register]` | `count` | Observe subscription created |
| `[:macrina, :observe, :notify]` | `bytes`, `count` | Notification pushed |
| `[:macrina, :observe, :cancel]` | `count` | Observe subscription cancelled |

## License

MIT
