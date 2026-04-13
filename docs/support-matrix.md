# Support Matrix

This document defines Macrina's intended support surface for the current release.

## Runtime support

| Area | Status | Notes |
| --- | --- | --- |
| Elixir | Supported | `~> 1.14` |
| Erlang/OTP | Supported | Use an OTP release supported by your Elixir 1.14 runtime |
| Linux | Supported | Primary development environment |
| macOS | Expected to work | No platform-specific code paths |
| Windows | Not explicitly supported | WSL is the recommended path if needed |

## Network support

| Area | Status | Notes |
| --- | --- | --- |
| UDP transport | Supported | Core transport model |
| IPv4 tuple addresses | Supported | Public client/server APIs use tuples |
| IPv6 tuple addresses | Supported | Address formatting and transport support exist |
| DTLS | Not supported | Out of scope for the current release |
| CoAP over TCP | Not supported | Out of scope for the current release |
| WebSockets | Not supported | Out of scope for the current release |

## Protocol feature support

| Feature | Status | Notes |
| --- | --- | --- |
| Request/response messaging | Supported | Confirmable and non-confirmable messages |
| Retransmission | Supported | Exponential back-off for confirmable traffic |
| Block1 uploads | Supported | Atomic and streaming modes |
| Block2 downloads | Supported | Automatic client reassembly |
| Observe | Supported | Client subscribe/cancel, server notifications |
| Discovery | Supported | `/.well-known/core`, `application/link-format` |
| Content negotiation | Supported | `Accept`-based resource dispatch |
| Proxying | Not supported | Not implemented |
| OSCORE | Not supported | Not implemented |
| Multicast discovery | Not supported | Not implemented |

## Public entrypoints

New application code should start from these modules:

- `Macrina.Server`
- `Macrina.Client`
- `Macrina.Request`
- `Macrina.Response`
- `Macrina.Router`
- `Macrina.Resource`

Internal modules such as `Macrina.Connection.Server`, `Macrina.Exchange`, and
`Macrina.Message` are stable enough for library maintenance, but they are not
the intended starting point for application developers.
