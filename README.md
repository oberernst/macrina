# Macrina

Saint Macrina, patron of Robotics, ora pro nobis
---
UNDER CONSTRUCTION! It's still a rough draft that I'm ripping to shreds constantly. LMK if you'd like this to change
* CoAP binary request encoding and decoding (RFC 7253.3)
* Endpoint 
  * can receive and decode messages
  * de-dups messages based on incoming IP/Port and `message_id`
  * echoes requests
  * can be started with arbitrary `handler` function for extending functionality

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `macrina` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:macrina, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/macrina>.

