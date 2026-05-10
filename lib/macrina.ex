defmodule Macrina do
  @moduledoc """
  Root module for the Macrina CoAP library.

  Macrina is an Elixir implementation of the Constrained Application Protocol
  (CoAP, RFC 7252) for machine-to-machine communication over Endpoint. It provides
  a client, server, and codec layer with support for:

    * Confirmable and non-confirmable messages with automatic retransmission
    * Block1 (upload) and Block2 (download) transfers (RFC 7959)
    * Observe subscriptions and server-push notifications (RFC 7641)
    * CoRE Link Format discovery via `/.well-known/core` (RFC 6690)
    * Per-resource content negotiation and path-parameter routing
    * `:telemetry` instrumentation across the full request lifecycle

  ## Architecture

  ```
  Macrina.Server / Macrina.Client
        │
  Macrina.Endpoint          ← Endpoint socket (GenServer over :gen_udp)
        │
  Macrina.Peer.Session ← per-peer GenServer (CON/NON/ACK/RST)
        │
  Macrina.Handler           ← dispatches to raw modules or Routers
  ```

  Each incoming Endpoint peer spawns a `Macrina.Peer.Session` under a
  `DynamicSupervisor`. Pure protocol state (tokens, message IDs, block
  transfers, retransmission tracking) lives in `Macrina.Exchange`.
  """
end
