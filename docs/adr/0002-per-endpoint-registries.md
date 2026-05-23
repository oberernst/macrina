# 0002 — Per-endpoint registries, not VM singletons

Status: Accepted (2026-05-23, part of the 1.0 refactor).

## Context

Pre-1.0 Macrina kept three pieces of state in VM-wide singleton
processes:

- `Macrina.Observe` — a single `GenServer` with hand-maintained
  `subscriptions` / `paths` / `connections` indexes, plus a
  `drop_connection/1` eviction call run from every session's
  `terminate/2`.
- `Macrina.Peer.Session` — registered as `{:global, {Session,
  peer_label}}`, sharing a name space with every other endpoint on the
  BEAM.
- `Macrina.BlockTransfer` (ported forward from master) —
  `:global`-registered per `{ip, token}`, same conflict surface.

Two endpoints in the same BEAM would either fight over names or
shovel each other's data through one shared queue. Both are
unacceptable for a library people host inside their app.

## Decision

The 1.0 refactor introduces two registries, both started by
`Macrina.Application`:

- `Macrina.Registry` — an Elixir `Registry` with `keys: :unique`. The
  module provides an Oban-style `via/2,3` wrapper. Used for
  `{:session, peer_label}`, `{:block_transfer, ip, token}`, and any
  future per-endpoint singleton.
- `Macrina.Observe.Registry` — an Elixir `Registry` with
  `keys: :duplicate`, keyed by `{endpoint_pid, normalized_path}`,
  with each subscription's `{token, atomics_ref}` as the value.

Subscribers self-register from the owning `Macrina.Peer.Session`, so
the Registry's built-in pid monitor evicts entries when the session
exits. `drop_connection/1` is gone. Sequence numbers live in
per-subscription `:atomics` refs and are bumped lock-free during
`notifications/2`.

## Consequences

- The `Macrina.Observe` GenServer disappears. The module shrinks from
  257 LOC of state-machine plumbing to a 121-LOC Registry wrapper.
- Two endpoints in one BEAM can subscribe to the same path without
  cross-contamination. Two endpoints with the same `{ip, token}`
  carry isolated Block1 transfers.
- `Macrina.Observe.register/4` becomes `subscribe/3` — `connection`
  is implicit (`self()`); the caller must be the owning session.
  `Macrina.BlockTransfer.handle_block/4` and `cache_completion/3`
  gain a leading `endpoint` argument and become `/5` and `/4`.
- Multi-endpoint isolation is pinned in `test/observe_test.exs` and
  `test/block_transfer_test.exs`.
