# 0003 — Security scope: OSCORE and DTLS deferred to 1.1+

Status: Accepted (2026-05-23, part of the 1.0 refactor).

## Context

Macrina 1.0 ships as a CoAP-over-plain-UDP library (RFC 7252) with
Block-wise (RFC 7959), Observe (RFC 7641), CoRE Link (RFC 6690), and
RFC 9175 §3.2 Request-Tag correlation. CoAP's two production-grade
secure transports — OSCORE (RFC 8613) and DTLS (RFC 9147) — are
substantial undertakings on their own; each wants its own design pass
and review.

## Decision

OSCORE, DTLS, and CoAP-over-TCP (RFC 8323) are explicitly out of
scope for the 1.0 release. To keep the door open for them, 1.0 lands
a `Macrina.Transport` `@behaviour` with `Macrina.Transport.UDP` as
the only implementation. `Macrina.Endpoint.start_link/1` takes a
`:transport` option (defaulting to UDP) and threads the module
through the session and state. A future DTLS or coap+tcp module can
land as an additional implementation without churning the
`Macrina.Endpoint` / `Macrina.Peer.Session` shells.

## Consequences

- The 1.0 surface includes the `Macrina.Transport` behaviour but no
  alternative implementation. The seam is real; the user-visible
  contract is that picking a non-UDP transport will at minimum
  require a new behaviour impl module.
- Security-sensitive deployments should not consider this 1.0 a
  drop-in replacement for libcoap or aiocoap with DTLS until the
  follow-up release lands.
- No OSCORE/DTLS code, configuration, or tests live in the 1.0 tree;
  references in documentation are explicit "post-1.0" markers.
