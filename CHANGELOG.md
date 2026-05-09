# Changelog

All notable changes to Macrina are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `Macrina.conn_name/2` is now `Macrina.Peer.label/2`. `Macrina.Peer` is the
  new internal home for peer-identity helpers; the old function has been
  removed without a deprecation shim (no public-API guarantees pre-1.0).
- Marked implementation modules as internal (`@moduledoc false`) to sharpen the
  documented public surface: `Macrina.Application`, `Macrina.Peer.State`,
  `Macrina.Peer.Session`, `Macrina.Transport.UDP`, `Macrina.Exchange`,
  `Macrina.Handler`, `Macrina.Blockwise`, `Macrina.Codes`, `Macrina.Types`,
  `Macrina.ContentFormat`, `Macrina.Message.Opts`, `Macrina.Message.Opts.Binary`.
- Replaced the raising `Macrina.Types.parse/1` shim with a non-raising
  `Macrina.Types.decode/1` call inside the message decoder. The unused
  `Macrina.Codes.parse/1,2` helpers were removed.
- `Macrina.Server.start_link/1` no longer re-normalises the `:block1` option;
  `Macrina.Transport.UDP` is the single site that expands a `Macrina.Block1` policy
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
