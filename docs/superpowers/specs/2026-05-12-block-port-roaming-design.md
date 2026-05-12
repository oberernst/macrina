# Block-Wise Transfer Port Roaming — Design Spec

- **Date:** 2026-05-12
- **Branch:** `block-port-roaming`
- **Status:** Draft, pending implementation plan
- **Author:** Claude (Opus 4.7) with Ernesto

## 1. Problem

A CoAP client (typically a NAT'd cellular/IoT device) sends Block1 number 0
from source port A, then a NAT rebind — or device-side socket rotation —
causes Block1 number 1 to arrive from the same IP but a new source port B,
under the same CoAP Token.

Macrina today keys all per-peer state, including the Block1 assembly buffer,
by `{ip, port}` via `Macrina.conn_name/2` and the `:global` name
`{:global, {Macrina.Connection.Server, conn_name}}`. The roamed packet
therefore starts a *new* `Connection.Server` with an empty `blocks` map,
pushes block 1, and `Macrina.Connection.read_blocks/1` returns `nil` because
block 0 is missing. The server replies `4.08 Request Entity Incomplete` and
the upload fails, while the original server idles on block 0 until its
5-minute timeout fires. Two `Connection.Server`s hold partial state for the
same logical transfer — the "double cache" symptom.

RFC 7252 §1.2 anchors endpoint identity to `{ip, port}` over UDP, so a
strict reading would say the client is at fault. In practice, the major
CoAP implementations (Californium 3.0 in particular, via its
`EndpointIdentityResolver` / `PrincipalEndpointContextMatcher` /
`RESPONSE_MATCHING` machinery) treat blockwise transfers as an exception
and correlate them by a stronger identity than the socket address — for
plain UDP, the Token, which RFC 7959 designates as the operation-level
correlator.

## 2. Goals and non-goals

**Goals.**

1. A device whose source port changes mid-transfer should still complete a
   Block1 upload, provided the Token is held constant across packets
   (RFC 7959 §2 conformance on the device side).
2. The fix must work correctly in a clustered deployment where a UDP load
   balancer can route a roamed packet to a different BEAM node.
3. Macrina must remain a pure UDP/CoAP library — no new dependencies, no
   Postgres, no Phoenix, no Docker.
4. RFC 7252 endpoint identity for *non-block* exchanges stays `{ip, port}`;
   dedup and last-reply behavior for single-datagram requests does not
   change.

**Non-goals.**

1. Block2 (download) roaming is out of scope. The Block1 (upload) path is
   the production pain point; Block2 can be tackled later by lifting the
   same primitive into the download side.
2. DTLS / Principal-based identity. Macrina is plain UDP today; the design
   should be evolvable toward Principal identity but does not introduce it.
3. Process handoff via Horde or similar. The BlockTransfer process stays on
   its first-elected node for the life of the transfer.

## 3. Background research

Californium 3.0 (`MIGRATION_HINTS.md`):

> "In order to support peers with dynamically assigned ip-addresses,
> Californium introduced the `EndpointIdentityResolver` for tokens and
> MIDs … With 3.0 this will now be extended for blockwise transfers. If
> used on the server-side, that enables a client-side to PUT/POST payload,
> even if a quiet phase causes an address change."

libcoap keys sessions by `coap_address_t` (IP+port) with no built-in
roaming tolerance for blockwise transfers. aiocoap likewise sticks to
socket-address keying.

The design adopts Californium's *principle* (attach blockwise state to a
stronger identity than the socket address) and applies it to plain UDP by
using the Token as the correlator, matching RFC 7959 §2.

## 4. Approach

Pull blockwise assembly state out of `Macrina.Connection.Server` and into
a new per-`{ip, token}` GenServer, `Macrina.BlockTransfer`, registered
globally as `{:global, {Macrina.BlockTransfer, ip, token}}`. The transfer
process holds only the accumulator and the cached completion reply; it
owns no socket. `Connection.Server` remains the per-`{ip, port}` socket
shell and, on receiving a Block1 message, delegates to the BlockTransfer
process, which returns an action tuple that `Connection.Server` translates
into a UDP send over its local socket.

This decouples block-assembly identity from socket-address identity. A
roamed packet hitting a fresh `Connection.Server` (possibly on a different
cluster node) finds the existing BlockTransfer via `:global.whereis_name/1`
and contributes its block to the same accumulator.

### 4.1 Why this approach over the simpler alternative

A smaller fix — having a new `Connection.Server` look up an existing peer
by `{ip, token}` and "steal" its block state during `init` — was considered
and rejected. It addresses the port-roaming case but conflates two
concerns in `Connection.Server` (socket shell + assembly buffer) that the
project's Wave B refactor plan already targets for decomposition.
Extracting `Macrina.BlockTransfer` now resolves the bug *and* makes
progress on Wave B without making the future split harder.

## 5. Cluster behavior

The reactmobile-api-elixir deployment that consumes Macrina runs a
libcluster-connected BEAM cluster behind a UDP load balancer that hashes
the 5-tuple `{src_ip, src_port, dst_ip, dst_port, proto}`. A change in
source port can route a roamed packet to a different node.

Three constraints govern the cluster design:

1. **`:gen_udp` sockets are node-local.** A reply must leave the cluster
   from the same node that received the packet.
2. **`:global` is already in use** for `Connection.Server` registration,
   giving cluster-wide uniqueness and built-in race resolution.
3. **`:global` is acceptable for the cluster sizes the consumer runs**
   (single-digit to low-double-digit nodes). At very large scale we can
   swap in `Horde.Registry` without changing the BlockTransfer's public
   interface.

### 5.1 Cross-node packet flow

```
Block 0 from {ip, port_A} lands on N1.
  N1 Endpoint starts Connection.Server({ip, port_A}) on N1.
  Connection.Server looks up {:global, {BlockTransfer, ip, token}} → :undefined.
  Connection.Server starts a new BlockTransfer locally on N1.
  Connection.Server forwards the Message to BlockTransfer.
  BlockTransfer pushes block 0, returns {:continue, ack_bin}.
  Connection.Server sends ack_bin via N1's :gen_udp socket.

Block 1 from {ip, port_B} lands on N2 (LB rerouted).
  N2 Endpoint starts Connection.Server({ip, port_B}) on N2.
  Connection.Server looks up {:global, {BlockTransfer, ip, token}} → pid on N1.
  Cross-node GenServer.call to N1's BlockTransfer pid.
  BlockTransfer pushes block 1, sees more: false, assembles payload,
    returns {:assembled, full_msg}.
  N2's Connection.Server invokes the application handler, sends the
    final reply via N2's :gen_udp socket, then calls
    BlockTransfer.cache_completion(ip, token, reply_bin).
  BlockTransfer enters :complete phase with EXCHANGE_LIFETIME timeout.
```

The orphaned `Connection.Server` on N1 holds no relevant state (block
assembly was never in it) and idle-times-out harmlessly.

### 5.2 Cluster edge cases

| Case | Behavior |
|---|---|
| `:global` race on simultaneous block 0 from two ports | One node wins registration; the loser receives `{:already_started, pid}` and discards its local child. All subsequent blocks route to the winner via cross-node call. |
| Net split during transfer | Both halves accept blocks independently. On heal, `:global`'s name resolver kills one. The affected device gets `4.08` on its next block and retransmits from scratch. |
| Single-node deployment (no libcluster) | `:global` degenerates to single-node; all calls are local; behavior is unchanged from the multi-node case minus the cross-node hop. |
| Cross-node hop latency | One extra `GenServer.call` per roamed block over a sub-millisecond local cluster network. Negligible. |

## 6. Module surface

### 6.1 New modules

#### `Macrina.Blocks` (pure)

Pure functions extracted from the current `Macrina.Connection`. No
process, no state — just data transformations on the accumulator map.

```elixir
@type acc :: %{non_neg_integer() => binary()}

@spec push(acc, Macrina.Message.t()) :: acc
@spec read(acc) :: {:ok, binary()} | {:error, {:missing, non_neg_integer()}}
@spec empty() :: acc
```

`read/1` returns a tagged tuple instead of the current `binary | nil` so
the calling code can pattern-match cleanly.

#### `Macrina.BlockTransfer` (GenServer, `:global`-registered)

```elixir
defstruct [
  :ip,          # :inet.ip_address(), part of the registry key
  :token,       # binary, part of the registry key
  :handler,     # module() passed in at start, used to invoke the app on assembly
  :blocks,      # Macrina.Blocks.acc()
  :last_reply,  # binary | nil, cached completion reply for token dedup
  :phase        # :assembling | :complete
]
```

Public API:

```elixir
@spec handle_block(
        :inet.ip_address(),
        binary(),
        module(),
        Macrina.Message.t()
      ) ::
        {:continue, binary()}
        | {:assembled, Macrina.Message.t()}
        | {:incomplete, binary()}
        | {:duplicate, binary()}
def handle_block(ip, token, handler, message)

@spec cache_completion(:inet.ip_address(), binary(), binary()) :: :ok
def cache_completion(ip, token, reply_bin)
```

`handle_block/4` is the single entry point used by `Connection.Server`.
Internally it does:

1. `:global.whereis_name({Macrina.BlockTransfer, ip, token})`.
2. If `:undefined`, start one via the supervisor; handle the
   `{:already_started, pid}` race by discarding the loser.
3. `GenServer.call(pid, {:block, message})`.

The returned action tuple tells `Connection.Server` exactly what UDP
payload to emit:

- `{:continue, ack_bin}` — push another block, send a `2.31 Continue` ACK.
- `{:assembled, full_msg}` — invoke handler, send its reply, then call
  `cache_completion/3`.
- `{:incomplete, ack_bin}` — gap detected on `more: false`; send
  `4.08 Request Entity Incomplete`.
- `{:duplicate, bin}` — retransmission of the final block inside
  `EXCHANGE_LIFETIME`; resend the cached completion reply.

Timeouts:

- `:assembling` phase — 5 minutes (matches the existing
  `Connection.Server` idle timeout).
- `:complete` phase — `EXCHANGE_LIFETIME = 247 s` per RFC 7252.

#### `Macrina.BlockTransfer.Supervisor`

A `DynamicSupervisor`, one per node, supervising `BlockTransfer` GenServers
with `restart: :transient`. Added to `Macrina.Application`'s children list
alongside the existing `ConnectionSupervisor`.

### 6.2 Changed modules

#### `Macrina.Connection`

Remove the `:blocks` field from the struct and remove the block-handling
helpers (`push_block/2`, `read_blocks/1`, `reset_blocks/1`). The struct
now reflects what `Connection.Server` actually owns:
`%{callers, last_reply, handler, ids, ip, name, port, socket, tokens}`.

#### `Macrina.Connection.Server`

In the `descriptive_block` branches of `handle_info({:coap, packet}, _)`,
replace the inline block-assembly logic with a single
`Macrina.BlockTransfer.handle_block(state.ip, message.token, state.handler, message)`
call, then dispatch on the returned action tuple:

```elixir
case Macrina.BlockTransfer.handle_block(state.ip, message.token, state.handler, message) do
  {:continue, ack_bin} ->
    Connection.reply(state, ack_bin)
    {:noreply, reply_to_client(state, message), @timeout}

  {:assembled, full_msg} ->
    {state, reply_bin} = handle_and_capture(state, full_msg)
    Macrina.BlockTransfer.cache_completion(state.ip, message.token, reply_bin)
    {:noreply, reply_to_client(state, full_msg), @timeout}

  {:incomplete, ack_bin} ->
    Connection.reply(state, ack_bin)
    {:noreply, reply_to_client(state, message), @timeout}

  {:duplicate, nil} ->
    {:noreply, reply_to_client(state, message), @timeout}

  {:duplicate, bin} when is_binary(bin) ->
    Connection.reply(state, bin)
    {:noreply, reply_to_client(state, message), @timeout}
end
```

`handle_and_capture/2` is a small refactor of the existing private
`handle/2`: it runs the application handler, sends the reply over the
local socket, and returns `{new_state, reply_bin_or_nil}` so the caller
can pass the binary to `cache_completion/3`. The existing `handle/2`
swallowed the binary in `set_last_reply/3`; splitting it out is the only
change needed to expose the value.

A `nil` cached completion (handler chose not to reply) is preserved as
`{:duplicate, nil}` so a retransmission of the final block produces the
same "no response" behavior — matching the current single-datagram
semantics where a `nil` `last_reply` causes the dedup branch to send
nothing.

The single-datagram dedup path (`last_reply` field on the connection
struct, `last_token == token` branch) is untouched.

#### `Macrina.Application`

```elixir
children = [
  {DynamicSupervisor, name: Macrina.ConnectionSupervisor, strategy: :one_for_one},
  {DynamicSupervisor, name: Macrina.BlockTransfer.Supervisor, strategy: :one_for_one},
  ...
]
```

## 7. Failure modes

| Case | Behavior |
|---|---|
| Final block retransmitted within `EXCHANGE_LIFETIME` | BlockTransfer alive in `:complete` phase; returns `{:duplicate, cached_bin}`; Connection.Server resends. |
| Final block retransmitted after `EXCHANGE_LIFETIME` | BlockTransfer terminated; new one starts with only the final block; `Blocks.read/1` reports `{:error, {:missing, 0}}`; reply is `4.08`. Device re-uploads from scratch. Same as today for stale retransmits. |
| Two devices share a NAT IP *and* pick the same 8-byte token | Registry collision merges their blocks. Cryptographically negligible with 8-byte random tokens (RFC 7252 §5.3.1 recommended size). Document for consumers using shorter tokens. |
| Out-of-order blocks (2 before 1) | Push succeeds; `Blocks.read/1` on `more: false` detects gap; reply is `4.08`. Same as today. |
| Net split | See §5.2. |

## 8. Testing

Per workspace `CLAUDE.md`, red/green TDD for every commit. Tests precede
implementation in each phase of the plan.

1. **`test/blocks_test.exs`** — pure tests on `Macrina.Blocks`. Cover:
   empty, single block, ordered fill, unordered fill, gap detection,
   duplicate push (later block overwrites earlier with same number,
   matching current `Map.put` semantics).

2. **`test/block_transfer_test.exs`** — drive the GenServer directly.
   Cover: continue path, assembled path, incomplete path, duplicate
   path after `cache_completion`, idle timeout in each phase. Use
   `async: true`; manage process lifetimes per-test.

3. **`test/connection_server_test.exs`** — migrate existing block-assembly
   assertions out; replace with assertions that `Connection.Server`
   delegates correctly to `Macrina.BlockTransfer` and translates each
   action tuple into the right UDP send.

4. **`test/integration/block_port_roaming_test.exs`** — the bug repro on
   a single node. Bind a `Macrina.Endpoint`; from the test, open two
   UDP sockets on loopback (simulating ports A and B) sharing one token;
   send block 0 from socket A, then block 1 from socket B; assert
   socket B receives the final response and the application handler
   received the assembled message exactly once. `async: false`, real UDP.

5. **`test/integration/block_port_roaming_cluster_test.exs`** —
   cross-node version. Use `:peer.start/1` (OTP 25+; project is on
   OTP 28) to launch a slave node; have each node bind its own
   `Macrina.Endpoint` on a separate loopback port; send block 0 to N1,
   block 1 to N2; assert the BlockTransfer lives on N1 and the final
   response leaves N2's socket. Tagged `:cluster`, included in default
   `mix test` but excludable via `mix test --exclude cluster` if CI
   flakes on `:peer` startup latency.

Telemetry assertions follow the existing pattern in
`test/connection_server_test.exs` — attach a handler that forwards
events to `self()`, then `assert_receive`. New telemetry events for
this feature: `[:macrina, :block_transfer, :start]`,
`[:macrina, :block_transfer, :stop]`,
`[:macrina, :block_transfer, :roam]` (emitted when a `handle_block`
call finds an existing pid on a different node).

## 9. Public API and CHANGELOG impact

`Macrina.BlockTransfer` is internal (`@moduledoc false`). It is not
listed in the public surface in `CLAUDE.md`. The behaviorally visible
change is "Block1 transfers now survive a source-port change provided
the Token is constant," which goes in the CHANGELOG `[Unreleased]`
section under *Changed*.

The `Macrina.Connection` struct shape changes (`:blocks` field removed,
helpers removed). Per the 1.0 release plan, "no backwards compatibility
constraints from the current pre-1.0 surface" — rename and drop freely.

## 10. Risks and open questions

1. **`:global` registration latency at scale.** Acceptable for the
   current consumer's cluster size; reconsider if Macrina is adopted at
   ≥ 50-node deployments.
2. **Cross-node `GenServer.call` timeout.** Default 5 s should be fine
   for loopback-cluster latency, but a slow link between nodes could
   surface here. Mitigation: set an explicit, generous timeout on the
   internal `handle_block` call.
3. **Test flake on `:peer.start/1`** in CI. If observed, gate the
   cluster test behind a `:cluster` tag and run it separately.
