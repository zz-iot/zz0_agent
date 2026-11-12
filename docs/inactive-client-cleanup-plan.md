# Inactive client cleanup

Design and implementation checkpoint, 2026-11-12. Session expiry, UDP maintenance,
CLI policy and automated recovery checks are implemented. The operator has
confirmed default-timeout expiry and subsequent DDS receipt on physical boards;
see the [hardware record](pico-acceptance.md#operator-reported-result-2026-11-12).

## Problem and scope

The UDP agent has eight client slots. Explicit client deletion, replacement by a
new session and shutdown release resources, but a client that disappears can keep
a slot and its DDS graph indefinitely. Repeated abandoned clients can prevent new
clients from connecting.

Add configurable inactivity expiry to the existing session owner and UDP loop.
Reuse the checked backend factory close operation. No zzdds, zidl or client wire
format changes are planned. This work does not add reliable streams, heartbeat
handling, authentication, provider reload or a larger client registry.

The MicroZig transmit regression contribution is deferred until the pending
rejoin PR is resolved. Existing agent closeout and demo hardware documentation
will accompany their next implementation PRs rather than separate documentation
PRs.

## Proposed policy

- The normal executable defaults to 600 seconds without qualifying client traffic.
  `--client-idle-timeout-seconds=N` overrides it; `0` disables expiry. Reject
  duplicate flags, negative values, invalid numbers and duration overflow.
  Print the effective setting at serving startup. Check/inspect modes validate
  the option without running timers. This is an agent process option, so no
  resource/profile TOML or generated schema change is needed in this slice.
- Reusable Sessions/Server APIs default to expiry disabled, preserving existing
  callers. The normal executable explicitly supplies its policy. Expose the same
  option on the compatibility executable, keeping its default disabled to
  preserve its fixture behavior.
- Ten minutes is a starting operational default, not a protocol requirement.
  It exceeds the demo's five-minute maximum retry interval, but does not promise
  retention across an arbitrarily long WiFi outage. Quiet applications should
  increase the timeout or disable it. Future subscriptions will require reviewing
  this policy before applying it to receive-only clients.
- Use std.Io's monotonic awake clock, matching existing UDP timeout helpers.
  Wall-clock adjustments do not change expiry. On Linux suspended host time
  does not count toward this timeout. Timing tests inject timestamps directly.
- Do not evict a live client to admit another. A full table still rejects login
  if no expired slot can be successfully cleaned up.

## What counts as activity

Record an initial timestamp after successful registration. Refresh it when a
supported request from the registered peer/session has passed structural decoding
and routing. A valid request returning a negative STATUS still proves activity:
unknown object/reference, invalid sample or backend rejection must not expire a
client that is communicating. Backend success is not the activity criterion.

Successful same-session login on the managed forwarding path refreshes activity
and keeps the existing graph and counters, including peer rebinding behavior.
The validation-only compatibility fixture retains its historical login reset. Successful RESET keeps
the registration and refreshes activity; explicit client deletion removes it.

Malformed framing or request bodies, unsupported operations, rejected
multi-submessage packets, unknown sessions, endpoint conflicts and failed logins
do not refresh activity. Outgoing responses alone do not refresh it. A local
short output buffer must not cause mutation. Refresh before attempting UDP send,
so a send failure does not erase already-observed valid activity.

Do not infer activity solely from response length or status success. RESET has
no response, and a negative STATUS can represent a valid request. Use the internal
dispatch activity indication at the existing validation point,
without duplicating the protocol decoder in the session registry. Preserve the
public byte-count interface for existing callers where practical.

Once retirement starts, further packets cannot refresh or reopen that owner.
This policy is resource management, not proof of client identity: the existing
UDP registry is unauthenticated and replay/duplicate suppression remains separate.

## Expiry and reconnection

A client is due when elapsed time is greater than or equal to its configured
timeout. Perform maintenance before dispatch using a single sampled timestamp.
At the exact deadline expiry wins: a same-session CREATE_CLIENT is then a fresh
registration after successful cleanup; an ordinary stale request cannot revive
an expired graph.

For each due client:

1. Mark it closing before calling the existing backend factory close operation.
2. On success, clear the slot, including graph associations and statistics.
3. On failure, retain the owner, key, peer, session and all lifetime dependencies.
   Keep the slot blocked and retry; never overwrite it or release provider owners.

For a fixture without a backend factory, clearing the expired slot is sufficient.
Expired sessions receive no unsolicited wire notification. Ordinary requests for
a successfully removed session follow the existing unknown-session behavior.
A new CREATE_CLIENT with the same key/session can then open a fresh graph.
The Pico application's timeout/recreation path is expected to recover; tests must
prove recovery instead of treating a STATUS reply alone as sufficient evidence.

A pending failed close is not cancellable by same-session login or a different
key. A new-session login for that key must not bypass the retry deadline either.
After close succeeds, registration may proceed normally. Packets from an old
session remain stale; delayed packets that reuse the same peer/session cannot be
distinguished from new traffic by this slice. Existing generation separation and
fresh entity mappings remain necessary, but are not replay protection.

## Maintenance and failure handling

Use the existing single-threaded UDP owner. Do not introduce a timer thread or
concurrent access to Sessions. Scan the fixed eight slots on each maintenance
pass. Attempt each due close at most once per pass, continue past a failed close,
and retry that slot no sooner than one second later. This bounds the number of
close attempts, not the duration of a backend call; close may still block as it
does for explicit deletion today.

Choose receive deadlines from the earliest expiry or cleanup retry, combined
with any caller-supplied deadline. Run maintenance after receive timeout and
before datagram dispatch, including under continuous unrelated/malformed traffic.
With no clients or pending cleanup, and no caller deadline, blocking receive is
still appropriate. Maintenance alone must not consume --max-datagrams counts.
Keep serveOnce caller timeout behavior explicit: an internal maintenance timeout
continues waiting; an elapsed caller deadline still returns the existing timeout.

Report expiration, cleanup failure and eventual successful release with client
key and reason, without payload data. Rate-limit repeated cleanup diagnostics
per slot. A failed automatic close does not terminate service for other clients.
Shutdown remains checked: it retries outstanding owners and must not release the
factory/providers while any cleanup obligation remains.

## Implementation slices and acceptance

1. Add timestamped activity and maintenance to Sessions, with injected-time tests
   and fake backend close failures. Keep existing APIs usable with expiry off.
   Cover exact boundary, disabled expiry, valid negative STATUS, RESET,
   same-session login/rebinding, malformed/unsupported traffic, capacity recovery,
   failed-close retention, retry spacing, non-starvation of other slots and fresh
   same-key/session registration. Verify provider/client owner counts return to
   baseline, and that a short output buffer does not mutate state.
2. Connect monotonic time and receive deadlines in Server, wire the CLI policy
   into startup, and document operation/recovery. Test expiry with no incoming
   traffic, a continuously busy socket, caller deadlines, datagram count limits,
   malformed CLI values and cleanup failures without stopping other clients.
   Use fake time for policy tests and bounded synchronized UDP checks for loop
   wiring; avoid long sleeps and narrowly timed assertions in CI.
3. Add a real configured-provider integration check: create clients and DDS
   graphs, keep one client active while another expires, reclaim capacity,
   reconnect the expired client and recreate its graph, and confirm decoded DDS
   receipt from both clients. Include retryable cleanup with a wrapped factory
   where feasible. Use short test-only timeouts. Run existing core, startup,
   multi-library and compatibility checks in their established CI lanes.

Finish with a short hardware check using an explicitly short agent timeout and
the current firmware: interrupt one board's traffic long enough to expire it,
keep the other publishing, then restore it and confirm both consumers receive
samples. Existing long-timeout hardware acceptance is historical evidence, not
an expiry test. No new firmware should be needed unless recovery tests expose a
client/application issue.

## Specification boundary

The [DDS-XRCE 1.0 specification](https://www.omg.org/spec/DDS-XRCE/1.0/PDF)
remains the wire reference. This proposal defines a local retention policy for
our supported publishing subset; it does not claim a negotiated XRCE lease or
substitute a timer for reliable stream/heartbeat semantics. Document the policy
in the supported-subset audit when implementation lands. A broader subscription
or reliable-stream design must revisit which traffic demonstrates activity and
how intentional quiet periods are handled.

## Automated checkpoint

A loaded-provider fixture also injects failed expiry cleanup, verifies that the
client/factory/library remain owned through a failed shutdown, then retries
successfully before releasing the startup owner.

Core tests exercise injected time, cleanup failure/retry, capacity reuse, negative
STATUS activity, RESET and rebinding, plus UDP maintenance with no datagrams and
with a ready socket. Existing compatibility login semantics are preserved.
The multi-library test has a fourth DDS receipt phase: client 1 keeps writing
while client 0 expires, then client 0 logs in with the same key/session and must
rebuild its graph. Client 1's existing graph still matches CREATE/REUSE. All 24
distinct type/client/phase receipts are decoded by the separate consumer process.
Its finite datagram budget also verifies maintenance does not consume the budget.

The 70 core/fixture tests pass in Debug, ReleaseSafe and host LLVM TSan, as do
the configured startup checks and the four-phase multi-library DDS scenario.
The pinned independent eProsima compatibility client also passes. The current
ReleaseSafe normal executable and CounterStatus fixture are installed locally
for the physical-board expiry check. On 2026-11-12 the operator reported
observing expiry at the default 600 seconds and successful consumer receipt after
restoring the boards. Detailed per-trial logs and a short-timeout rerun were not
separately reported.
