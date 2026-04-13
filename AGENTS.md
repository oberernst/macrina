# Copilot Workspace Instructions for ReactMobile API Elixir

## Purpose
These instructions guide GitHub Copilot and similar AI agents to work productively and idiomatically in this codebase. They encode project-specific conventions, workflows, and pitfalls, referencing canonical documentation where possible.

---

## Workflow
- **Bias toward action:** Limit research to 1-2 searches, then propose a concrete fix. Trust user bug reports.
- **Testing:** Use `eval "$(~/.local/bin/mise activate bash)" && mix test` for all test runs. Always run `mix format` after code changes.
- **Local development:** Prefer local commands over Docker unless otherwise specified. Docker is used for full-stack local dev, but Elixir/Erlang are managed by `mise`.
- **Debugging:** Prefer plain print debugging over speculative reasoning.

## Style & Conventions
- **Aliases:** Always use aliases; never reference modules with full paths in code.
- **Unit tests:** Every function you write or alter must have a unit test. Use straightforward, in-place tests—avoid helpers unless necessary.
- **Test gold standard:** See `test/reactmobile_web/v5/beacon_controller_test.exs` for idiomatic test style: minimal helpers, terse but thorough comments, and Mox for mocking.
- **Documentation:** Prefer literate code with extensive comments. Assume high reader sophistication.
- **Mox:** Always use Mox for mocking in tests, never with_mock.

## Environment Setup
- **Elixir/Erlang:** Managed by `mise`, pinned in `.tool-versions`. All mix/elixir/iex/erl commands must be prefixed with `eval "$(~/.local/bin/mise activate bash)" &&`.
- **PATH issues:** Without the above prefix, Elixir resolves to a broken Windows install via WSL and will crash.

## Architecture & Boundaries
- **Boundaries:** Find the correct boundaries (pure core, effectful shell). Do not abstract prematurely. Prefer data > modules > processes.
- **Router:** See `lib/reactmobile_web/router.ex` for API boundaries and pipeline conventions.
- **Swagger/OpenAPI:** API spec is in `lib/reactmobile_web/v5/api_spec.ex`.

## Documentation
- **README.md:** Canonical for setup, commands, and architecture overview.
- **NOTES.md:** Contains migration, SSL, and local dev tips.

## Pitfalls
- **Mix commands:** Always use the mise prefix or commands will fail.
- **Certificates:** Only use generated self-signed certs for local dev.

## Example Prompts
- "Add a new endpoint to v5 API for device status."
- "Refactor OrgController to use new Org schema."
- "Write a unit test for AlertSessionController.create/2."

---

## Related Customizations
- Consider creating an agent hook to enforce the mise prefix on all Elixir commands.
- Add a skill for generating idiomatic Mox-based test scaffolds.