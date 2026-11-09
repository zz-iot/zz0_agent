# Client-owned backend adapter

`src/backend.zig`, exported as `zz0_agent.backend`, is the normalized
request/ownership boundary. It is exercised with both fake-backend tests and the
[real DDS adapter and managed UDP registry](real-dds-backend.md). Real forwarding
is the executable default, using the built-in CounterStatus configuration.
The compatibility fixture requires `--validate-only`. These tests do not establish full XRCE conformance.

## Configuration and ownership

A Catalog maps public definition names to resource definitions in a prepared DDS
plan. It describes allowed parent/topic definitions, a concrete participant domain,
the configured type's XCDR2 encoding and optional telemetry selection. It contains
no client object IDs, native handles or library paths. Definitions may be supplied
in any order; validation checks names, kinds and references before backend calls.
The real DDS adapter must also validate the names against its prepared plan and
verify the encoding against the selected type's extensibility. This module does
not add another TOML or QoS reader.

Each Client borrows the immutable catalog and a separate, initially empty backend
context. The future session registry must allocate stable client/backend storage
and keep it alive until cleanup succeeds. Never copy a populated owner or bind two
clients to one mutable graph. Reusing a catalog or provider preparation is allowed;
sharing mutable DDS entities between clients is not part of this contract.

The backend interface creates one configured resource, writes an encapsulated
sample, deletes a leaf, clears resources and reports whether failed creation/write
left cleanup obligations. Handles are local to that context. A real implementation
can adapt the slot/generation to its own zzdds Incremental owner. The caller owns
backend context allocation/destruction; clearing client resources does not free it.
A backend may lazily initialize a new graph on the next CREATE after clear, avoiding
allocation solely to make shutdown succeed.

## Request behavior

CREATE accepts a normalized definition and client object ID, plus actual parent/
topic IDs and domain where applicable. Protocol decoding will normalize defaults
and reject unsupported overrides before calling it. Publishers/writers must reach
this interface through their supported binary representation or an explicitly
selected compatibility path; this API is not a claim that by-reference forms are
standard for those object kinds.

The Client resolves IDs in its own association table and checks definitions and
participant instances. A publisher in one participant cannot use a topic from
another instance of the same participant definition. All slots are fixed capacity
(32, matching existing agent resource limits); capacity is reserved before backend
creation, and only backend success publishes the association.

REUSE compares the normalized definition and actual parents/topic. With immutable
configuration and a pinned backend, that also preserves the selected type generation.
Both creation flags clear return already-exists for an occupied ID. Matching REUSE
returns matched without backend calls, including when both flags are set. Requests
requiring replacement are explicitly denied for this first subset. Status mapping
is centralized and provisional until the selected wire operations are audited.
Original backend errors are retained in `last_error`; `cleanup_cause` separately
retains the failure blocking the owner even when later requests are rejected.

WRITE accepts one little-endian plain XRCE XCDR2 sample. It bounds the data to 512
bytes and adds the configured encapsulation: plain, delimited or parameter-list
CDR2. The backend must check the complete sample and key before writing, and must
consume borrowed bytes synchronously. There is no encoding sniffing or conversion.
Counters distinguish received, rejected and backend-accepted writes. A successful
result does not establish subscriber receipt. Telemetry selection is by definition,
not an object-ID constant; future dispatch must run optional telemetry only after
backend acceptance, without turning a telemetry decode failure into a failed write.

Leaf deletion checks both parent and topic dependencies. Successful backend deletion
removes the association. A failure retains the mapping and blocks subsequent work
until clear succeeds. Failed CREATE never inserts an association; if its backend
reports retained cleanup obligations, the client blocks further work as well.
Calls are serialized by the owner. Reentrant operations are rejected while a backend
call is active; clear cannot free a graph underneath an active operation.

Clear is the primitive for explicit reset, changed-session replacement and shutdown.
Partial cleanup failure retains the client/context and all associations for retry;
those associations cannot be used while blocked. Successful clear empties mappings
and leaves the backend usable. Same-session repeat login must preserve this owner
rather than clearing it. The managed UDP registry now follows these rules;
see [real backend sessions and cleanup](real-dds-backend.md#sessions-and-cleanup).

## Evidence and next integration

Tests use independent backend contexts with overlapping IDs, mixed participant
instances, all occupied-ID creation-flag combinations, missing dependencies,
capacity exhaustion, bounded XCDR2 framing, malformed writes, reentrant clear,
failed create/delete and partial cleanup retries. Existing UDP and demo tests remain
part of `zig build test`; no new external dependency is required for this step.

The selected binary CREATE and lifecycle codecs, managed session storage and real
DDS backend are implemented with a published zzdds 0.3.11 dependency. Packet
lifecycle tests and operator-reported Pico forwarding/recovery evidence are
recorded in [the real backend checkpoint](real-dds-backend.md). General startup
configuration and independent-vendor forwarding qualification remain. The
companion client's merged PR #2 commit is pinned in hosted CI.

## Packet integration checkpoint (2026-10-30)

At the earlier packet-only checkpoint, an explicit `Agent.backend_client` points
to a caller-owned stable Client. Managed UDP now uses a client factory instead. This
single-client path supports authorized by-reference participant/topic CREATE,
WRITE, leaf DELETE and RESET. Publisher/writer CREATE uses the bounded modern-XCDR2 binary codec (QoS absent).
The configured DDS topic name is distinct from its resource-plan key; ambiguous
publisher/writer selections are rejected.
STATUS-producing operations verify reply capacity before backend side effects and
preserve request correlation. RESET clears resources without inventing a STATUS
request ID. Client-object DELETE clears the injected backend; registry removal is
still the session layer's responsibility. Failed clear retains its owner for retry.
Only one submessage per datagram is supported here; multiple submessages are
rejected before side effects. This is a declared subset, not full stream support.

Accepted backend writes are recorded before optional definition-selected telemetry.
Malformed telemetry increments its diagnostic counter but cannot reverse backend
acceptance. The original demo path retains its existing validation behavior.
UDP templates explicitly reject an injected backend pointer until a client factory
can allocate independent contexts, preventing accidental graph sharing across clients.

Agent tests pass in Debug and ReleaseSafe, including short reply buffers, correlated
STATUS, cleanup retry and the telemetry distinction. The shared client codecs have
independent DELETE/RESET fixtures. See the companion zz0_client
[encoding audit](../../zz0_client/interop/binary-create-audit.md) for the explicit XTypes 1.3 decision.

Modern encoding tests include independently authored binary CREATE bytes, historical
delimiter rejection, generated appendable/nested/mutable bytes and an appendable
WRITE passing through packet dispatch into the generated decoder. These are not
evidence that the UDP backend or independent peer binary path is complete.

## Real backend follow-up

The initial fake-backend checkpoint above is now followed by
[real DDS construction and managed UDP sessions](real-dds-backend.md). The
single-client template guard remains: callers use bindBackend/a client factory,
not a shared injected backend pointer. Current native evidence and limitations
are recorded in that follow-up.
