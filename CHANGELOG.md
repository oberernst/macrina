# Changelog

All notable changes to Macrina are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `Macrina.Server.start_link/1`, `Macrina.Endpoint.start_link/1`, and
  `Macrina.Peer.Session.start_link/1` accept only `:router` (with optional
  `:context`). The legacy `:handler` keyword that took a bare module or a
  raw `{router, context}` tuple has been removed; `Macrina.Router` is the
  single dispatch contract. Internal callers were updated to pass
  `:router` + `:context` through to the session.
- `Macrina.Observe` is no longer a VM-singleton `GenServer`. State lives
  in `Macrina.Observe.Registry`, an Elixir `Registry` with `:duplicate`
  keys keyed by `{endpoint_pid, path}`. Subscriptions self-register from
  the owning `Macrina.Peer.Session` process, so when the session exits
  the Registry's pid monitor drops the subscription automatically — no
  `drop_connection` book-keeping. The public API surface is now
  `subscribe/3`, `cancel/3`, and `notifications/2`. Sequence numbers
  live in per-subscription `:atomics` refs (lock-free bumps inside
  `notifications/2`).
- `Macrina.Peer.Session` registers under
  `Macrina.Registry.via(endpoint_pid, {:session, peer_label})` instead
  of `{:global, {Session, peer_label}}`. Two `Macrina.Endpoint`s talking
  to the same peer in one BEAM no longer collide on the session name.
- `Macrina.BlockTransfer` keys its registration on
  `Macrina.Registry.via(endpoint_pid, {:block_transfer, ip, token})`
  instead of `:global`. `handle_block/5` and `cache_completion/4` take
  the endpoint pid as a leading argument; two endpoints with the same
  `{ip, token}` get isolated transfers.

### Added

- `Macrina.Telemetry` `@moduledoc` now ships the full 1.0 event
  catalogue — every `[:macrina, …]` event the library emits with its
  measurements and metadata keys. Additions are non-breaking; renames
  or removals will be called out in this file.
- ADRs documenting the three 1.0 architectural commitments:
  `docs/adr/0001-router-as-sole-dispatch.md`,
  `docs/adr/0002-per-endpoint-registries.md`,
  `docs/adr/0003-security-scope.md`.
- `.github/workflows/elixir.yml` now runs the full pre-PR gate on
  push and PR: `mix format --check-formatted`, `mix credo --strict`,
  `mix test`, `mix dialyzer`. PLT cache keyed on `mix.lock`.
- `test/message/codec_property_test.exs` — StreamData property tests
  pinning the two codec invariants we want to hold over an arbitrary
  input space: `encode → decode` preserves request semantics (code,
  id, token, type, payload, and option multiset), and
  `encode → decode → encode` is a fixed point. Tagged `:property`;
  runs by default.
- RFC 9175 §3.2 — Request-Tag (option 292). Registered in
  `Macrina.Message.Opts` and parsed/emitted by the codec like any
  opaque option. `Macrina.Blockwise.transfer_identity/1` now prefers
  Request-Tag as the body correlation key with Token as the fallback,
  so two block uploads sharing a Token but bearing different
  Request-Tags are treated as distinct bodies (matches NCS 2.9 and
  other implementations that rotate Request-Tag per body).
- RFC 7252 §4.2 — RST on malformed Confirmable. A new
  `Macrina.Message.decode_envelope/1` extracts `{id, type, token}`
  from the 4-byte CoAP header without parsing options, so when
  `Macrina.Message.decode/1` rejects a packet the session can still
  recover the matching id and send an empty RST when the original
  type was `:con`. Telemetry now carries the decode `reason` in
  `[:macrina, :connection, :decode, :error]`.
- `Macrina.Transport` — `@behaviour` for endpoint wire transports.
  Callbacks: `open/1`, `send/3`, `close/1`. Active-mode sockets deliver
  received datagrams to the controlling process as
  `{:udp, socket, ip, port, packet}`; alternate transports must mimic
  the shape.
- `Macrina.Transport.UDP` — the only impl in 1.0, a thin shim over
  `:gen_udp`. `Macrina.Endpoint.start_link/1` accepts a `:transport`
  option (defaulting to `Macrina.Transport.UDP`) and threads the
  module through to spawned `Macrina.Peer.Session` children via
  `Macrina.Peer.State`. All previously direct `:gen_udp.send` calls in
  `Macrina.Peer.Session` and `Macrina.Peer.State.reply/2` route
  through `state.transport.send/3`. The seam is reserved for DTLS /
  CoAP-over-TCP work post-1.0.
- `Macrina.Peer.Block1Server` — pure Block1 (RFC 7959 §2.5) server-side
  ingest. `ingest/3` takes the Block1 policy, the exchange accumulator,
  and an incoming message and returns one of `:continue`, `:assembled`,
  `:incomplete`, `:too_large`, or `:stream_chunk` alongside the next
  exchange. `Macrina.Peer.Session` interprets the decision and drives
  the I/O — handler invocation, UDP send, telemetry, dedup cache.
  Direct unit tests live in `test/peer/block1_server_test.exs`;
  `Peer.Session` shrinks from 1126 to 999 LOC as the inline Block1
  helpers (`maybe_continue_block1_transfer`, `block1_transfer_too_large?`,
  `stream_handler_result`, `block1_response_options`, etc.) move out
  and consolidate behind `apply_block1_decision/3`.
- `Macrina.Registry` — an Elixir `Registry` with unique keys, started by
  `Macrina.Application`, intended for `{endpoint_name, role}` lookups
  by `Macrina.Peer.Session`, `Macrina.BlockTransfer`, and any future
  per-endpoint process.
- `Macrina.Observe.Registry` — a duplicate-keys `Registry` that backs
  `Macrina.Observe`. Two-endpoint isolation tests pin the contract
  (`test/observe_test.exs`, `test/block_transfer_test.exs`).
- `Macrina.Blocks` — pure block-payload accumulator. Stores blocks keyed
  by number, reads them back as a contiguous binary, and reports the first
  missing block on a gap. Used by `Macrina.BlockTransfer` for Block1
  upload reassembly.
- `Macrina.BlockTransfer` — per-`{endpoint, ip, token}` GenServer for
  Block1 upload assembly with a separate assembling/complete phase,
  completion caching for retransmits. `Macrina.BlockTransfer.Supervisor`
  added to the application supervision tree.
- `config/config.exs` — Logger console formatter with a metadata
  allowlist matching the `[Category] message + metadata kw list` log
  convention used by `Macrina.BlockTransfer`.

### Removed

- The `Macrina.Observe` GenServer (`use GenServer`, the three-index
  `subscriptions`/`paths`/`connections` state machine, the
  `pop_subscription` / `delete_from_index` plumbing, and the dead-
  connection eviction loop). All of it is replaced by a 121-LOC
  Registry-backed module — the index is `Registry.lookup/2` and
  eviction is `Registry`'s pid monitor.
- `Macrina.Observe.drop_connection/1`. Session death drops subscriptions
  automatically via the Registry's pid monitor.

### Changed

- Per-endpoint atomic message-id counter. `Macrina.Endpoint` now owns
  an `:atomics` ref seeded at endpoint start; `Macrina.Peer.Session` reads it
  via `Macrina.Endpoint.next_message_id/1` (a pure ref-based helper —
  no GenServer round-trip per message). Sessions spawned outside a UDP
  endpoint (tests, ad-hoc setups) get a fresh per-session counter as
  fallback. Observer notifications and observe block2 follow-up requests
  use the counter; the random `Enum.random(10000..19999)` fallback in
  `Macrina.Message.build/2` remains for direct test fixture construction.
- Codec hot-path optimisations. `Macrina.Message.Opts.name/1` and
  `Macrina.Message.Opts.number/1` now use compile-time maps instead of an
  `Enum.find/2` linear scan over a 19-tuple list.
  `Macrina.Message.Opts.Binary.decode_block/3` uses `Bitwise.bsl/2` instead
  of `:math.pow |> Float.ceil |> trunc`, and `encode_block/3` uses an
  exhaustive 7-clause `szx_for_size/1` lookup instead of `:math.log2 |>
  Float.ceil |> trunc`. All exact integer arithmetic; no floating-point.
- `Macrina.Message.build/2` no longer encodes options twice. Added a new
  `Macrina.Message.Opts.Binary.validate/1` that runs the same shape, name,
  and value checks as `encode/1` but stops short of allocating the encoded
  binary. `validate_options` now uses it; the actual byte serialisation only
  happens once, at `Macrina.Message.encode/1` time.
- `Macrina.conn_name/2` is now `Macrina.Peer.label/2`. `Macrina.Peer` is the
  new internal home for peer-identity helpers; the old function has been
  removed without a deprecation shim (no public-API guarantees pre-1.0).
- Marked implementation modules as internal (`@moduledoc false`) to sharpen the
  documented public surface: `Macrina.Application`, `Macrina.Peer.State`,
  `Macrina.Peer.Session`, `Macrina.Endpoint`, `Macrina.Exchange`,
  `Macrina.Handler`, `Macrina.Blockwise`, `Macrina.Codes`, `Macrina.Types`,
  `Macrina.ContentFormat`, `Macrina.Message.Opts`, `Macrina.Message.Opts.Binary`.
- Replaced the raising `Macrina.Types.parse/1` shim with a non-raising
  `Macrina.Types.decode/1` call inside the message decoder. The unused
  `Macrina.Codes.parse/1,2` helpers were removed.
- `Macrina.Server.start_link/1` no longer re-normalises the `:block1` option;
  `Macrina.Endpoint` is the single site that expands a `Macrina.Block1` policy
  into raw connection options. Behaviour is unchanged.
- `Macrina.Peer.State` now stores the Block1 policy as a single
  `:block1` field (a `%Macrina.Block1{}` struct) rather than three sibling
  `block1_*` fields. The raw keyword options on `Macrina.Peer.Session`
  still accept `:block1_max_body_size`, `:block1_mode`, and
  `:block1_preferred_block_size`; internally they are folded into the policy
  struct.
- Extracted the pure observe-client bookkeeping into
  `Macrina.Observe.ClientSession` (internal); `Macrina.Peer.Session`
  now delegates the subscription/transfer/staleness state machine there.
- Extracted the pure reply-cache helpers into `Macrina.Exchange.Dedup`
  (internal); `Macrina.Exchange.cache_reply/4` and `cached_reply/4`
  delegate to it.
- Removed the dead `@callback Macrina.Handler.call/2` declaration. No module
  declared `@behaviour Macrina.Handler`; handlers pass a plain module that
  exports `call/2`.

### Added

- Development tooling: `:credo`, `:dialyxir`, `:stream_data`, `:benchee`,
  `:excoveralls` (all `only: [:dev, :test]`).
- `CHANGELOG.md` and `CONTRIBUTING.md`.

## [0.1.4]

- Prior history lives in the Git log.
