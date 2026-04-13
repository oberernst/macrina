# Observe and Blockwise Transfers

This guide covers Macrina's support for long-lived subscriptions and large
payload transfers.

## Observe

Observe lets a client subscribe to changes on a resource and receive pushed
notifications from the server.

### Client side

```elixir
{:ok, client} = Macrina.Client.connect(ip: {127, 0, 0, 1}, port: 5683)
request = Macrina.Request.from_uri!(:get, "/temperature")

{:ok, subscription, initial_response} =
  Macrina.Client.observe(client, request, notify_to: self())

receive do
  {:macrina_observe, ^subscription, notification} ->
    IO.inspect(notification.payload, label: "updated temperature")
end
```

### Server side

Push an updated value to all observers of a path with `Macrina.Server.notify/3`:

```elixir
{:ok, count} =
  Macrina.Server.notify(server, "/temperature",
    Macrina.Response.new(:content, payload: "23.1 C", content_format: :text_plain)
  )
```

## Block2 downloads

When a server replies with blockwise `Block2` responses, `Macrina.Client`
automatically follows the sequence and reassembles the final payload.

If you explicitly set `Block2` on the request, Macrina preserves that lower-level
intent and returns only the requested chunk.

## Block1 uploads

Server upload handling is controlled by a `Macrina.Block1` policy:

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

### Modes

- `:atomic` — the default. Your handler sees the fully reassembled payload.
- `:streaming` — the handler sees `Macrina.Block1.Chunk` values as blocks arrive.

Routers can opt into streaming uploads by implementing `block1/2`.

```elixir
@impl true
def block1(chunk, _context) do
  if chunk.complete do
    Macrina.Response.new(:changed)
  end
end
```