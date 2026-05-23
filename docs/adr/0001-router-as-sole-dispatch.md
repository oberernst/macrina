# 0001 — Macrina.Router as the sole dispatch contract

Status: Accepted (2026-05-23, part of the 1.0 refactor).

## Context

Pre-1.0 Macrina shipped two parallel ways to dispatch an incoming
request. A user could pass either a `:router` module implementing
`Macrina.Router`, or a `:handler` module implementing a bare `call/2`,
or even a raw `{router, context}` tuple under the `:handler` keyword.
The internal `Macrina.Handler` module existed as a dispatch shim
bridging these two surfaces. Plug, Phoenix, libcoap, and aiocoap all
have one such contract; Macrina's two were a redundant escape hatch.

## Decision

`Macrina.Router` is the only dispatch contract on the 1.0 surface.
`Macrina.Server.start_link/1`, `Macrina.Endpoint.start_link/1`, and
`Macrina.Peer.Session.start_link/1` all accept `:router` (with an
optional `:context` map). The bare-module `:handler` keyword is gone.
Internal callers (`Macrina.Server` → `Macrina.Endpoint` →
`Macrina.Peer.Session`) thread `:router` + `:context` as separate
keywords; the runtime stores the pair as `{router, context}` inside
the per-peer state.

## Consequences

- No deprecation shim; pre-1.0 callers using `:handler` get a clear
  `{:error, {:missing_option, :router}}` and a routes-to-router
  migration is the obvious fix.
- The `Macrina.Handler` module persists as an internal dispatch
  helper. It is `@moduledoc false` and may be inlined or renamed
  without notice.
- Test fixtures that used the bare-module callback shape were
  rewritten as one-liner Routers; that diff lives in the Phase 0
  commit.
