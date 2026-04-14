# Changelog

All notable changes to Macrina are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Marked implementation modules as internal (`@moduledoc false`) to sharpen the
  documented public surface: `Macrina.Application`, `Macrina.Connection`,
  `Macrina.Connection.Server`, `Macrina.Endpoint`, `Macrina.Exchange`,
  `Macrina.Handler`, `Macrina.Blockwise`, `Macrina.Codes`, `Macrina.Types`,
  `Macrina.ContentFormat`, `Macrina.Message.Opts`, `Macrina.Message.Opts.Binary`.
- Replaced the raising `Macrina.Types.parse/1` shim with a non-raising
  `Macrina.Types.decode/1` call inside the message decoder. The unused
  `Macrina.Codes.parse/1,2` helpers were removed.

### Added

- Development tooling: `:credo`, `:dialyxir`, `:stream_data`, `:benchee`,
  `:excoveralls` (all `only: [:dev, :test]`).
- `CHANGELOG.md` and `CONTRIBUTING.md`.

## [0.1.4]

- Prior history lives in the Git log.
