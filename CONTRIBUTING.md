# Contributing to Macrina

Thanks for considering a contribution. Macrina is working toward a stable 1.0
release; contributions that move us in that direction are very welcome.

## Getting set up

```bash
git clone https://github.com/oberernst/macrina.git
cd macrina
mix deps.get
mix test
```

The pinned Elixir/OTP versions live in `.tool-versions`.

## Before opening a pull request

Run the full local check:

```bash
mix format --check-formatted
mix credo --strict
mix test
mix dialyzer    # first run will build PLTs; subsequent runs are fast
```

CI runs the same commands on every PR.

## What we look for

- **Tests for every behavior change.** Unit tests for pure modules; integration
  tests for anything crossing the transport boundary.
- **Telemetry for new observable events.** Add to `Macrina.Telemetry` and
  document in the README table.
- **No new public API without `@moduledoc` and `@spec`.** Everything internal
  should be marked `@moduledoc false`.
- **Small, focused commits.** A PR that does one thing is almost always
  preferable to one that does five.

## Reporting bugs

Open an issue with:

- A reduced reproducer (`.exs` script or failing test case).
- The Elixir/OTP versions you're on.
- Any relevant telemetry events you captured.

## Security

Please do not file public issues for security vulnerabilities. See
[SECURITY.md](SECURITY.md) for the responsible disclosure process.

## Code style

- `mix format` is authoritative.
- Prefer left-aligned code: name intermediate values; avoid deep nesting.
- Public APIs return tagged tuples by default; reserve raising for explicit
  `!` variants.
- Module naming follows the RFC 7252 vocabulary where possible.

## License

By contributing, you agree that your contributions will be licensed under the
MIT license, the same license as the project.
