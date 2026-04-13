# Known Limitations

Macrina covers the core single-peer CoAP workflow well, but the current release
deliberately does not try to solve every protocol extension.

## Not implemented

- DTLS
- OSCORE
- CoAP over TCP
- HTTP proxying
- multicast discovery
- advanced caching/proxy semantics beyond per-connection duplicate reply caching

## Operational boundaries

- The primary transport is UDP via `:gen_udp`.
- A `Macrina.Connection.Server` process is created per remote peer.
- Idle peer connections time out after five minutes of inactivity.
- Automatic Block2 collection only applies when the request does not already set `Block2`.
- Observe notification delivery is process-message based on the local node:
  `{:macrina_observe, subscription, response}`.

## API boundaries

- `Macrina.Server` and `Macrina.Client` are the intended public entrypoints.
- Low-level modules such as `Macrina.Message` and `Macrina.Exchange` are available,
  but most users should not need them.
- The example scripts and guides are written against the public surface only.

## Documentation contract

A new user should be able to:

- start a server from the README or Getting Started guide
- connect a client and send a request without reading internal modules
- add routing, discovery, observe, and blockwise behavior from the guides