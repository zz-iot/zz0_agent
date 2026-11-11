# DDS backend implementation plan

Follow-on: [configurable startup](configurable-startup-plan.md) covers removing
the built-in sample, loading multiple libraries and reusing shared resource profiles.

Design checkpoint: 2026-10-29. Slice 3 is merged in zzdds PR #113;
this document scopes slice 4. No DDS forwarding is implemented by this document.

Dependency checkpoint (2026-11-09): zzdds PRs #125 and #128 are merged and
released in **0.3.11**. The agent and Pico DDS consumer now pin that release,
including incremental construction, explicit endpoint encoding, provider ABI
exports and logical handle retirement. Its zidl 0.3.27 supplies one shared
code-generation/runtime dependency.
The [real backend and managed UDP ownership](real-dds-backend.md) are implemented,
with modern binary CREATE, checked DDS writes, RESET and client deletion. DDS
forwarding is the executable default. Both Pico boards have operator-reported
consumer receipt and recovery after agent restart, Pico WH reset and WiFi loss.
The companion client [wire audit](../../zz0_client/interop/binary-create-audit.md)
records the explicit XTypes 1.3 encoding decision. CI pins the merged client PR #2
commit. Configured provider/catalog startup is now implemented as described in
the follow-on checkpoint below; independent-vendor forwarding remains further work.
The existing disabled-parent child-deletion limitation remains; no atomic staging
guarantee was added.

The first useful result is a client-created participant, topic, publisher and
writer that publishes checked samples into DDS and releases its resources safely.
Resource definitions and provider selections are process configuration. XRCE
object IDs and mutable DDS entities belong to individual clients.

## Original findings (2026-10-29)

| Area | Current implementation | Required change |
| --- | --- | --- |
| CREATE | `Agent.handleDatagram` validates a reference and stores descriptive fields | Construct the requested DDS object before committing its XRCE association |
| Reference authorization | `ReferenceDefinition` can require fixed parent object IDs | Require a parent definition and resolve its actual ID in the requesting client's table |
| WRITE_DATA | Accepts little-endian FORMAT_DATA; demo object ID selects CounterStatus decoding | Resolve a real writer, validate with its provider, then write; telemetry observes the result |
| Sessions | `ClientSessions` replaces an existing Agent value on every login | Preserve repeated sessions; clean up changed sessions before replacing their owners |
| Shutdown | `UdpServer.close` closes the socket and discards session storage | Close client graphs before releasing provider/configuration storage |
| DELETE / RESET | No dispatch handling | Add bounded decoding and lifecycle operations, with retryable cleanup ownership |
| Shared builder | `resources.Instance.build` constructs the entire application | Add incremental operations without creating unrequested endpoints |
| Representation | Builder fixes endpoint QoS to XCDR1; demo decoding frames XCDR2 | Make endpoint representation explicit and validate provider support |
| Dependencies | Agent has no zzdds dependency; zidl is v0.3.21 | Pin a merged zzdds commit and align generated-code/runtime dependencies |

Inspected zz0_agent baseline: `a4d7080`. Inspected zzdds checkout:
`5f4aef71958d7859d62825bbeffd230c16012edc` (PR #113 branch head).
Resolve and record the actual merged-main commit and package hash when adding the
agent dependency. Do not use a moving branch URL. A developer override may select
a sibling checkout; CI must exercise the pinned package too.

## Shared construction work in zzdds

Keep construction, QoS translation, type registration and reverse-order cleanup
in zzdds. Do not add XRCE request/status types to the library.

Add an owner for incremental construction over an immutable resolved plan and
prepared bindings. It allocates bookkeeping before DDS calls and exposes operations
for one participant, topic, container or endpoint at a time. Operations identify
plan definitions and already-created parent handles. They must allow independent
instances of a definition; a definition name alone is not a mutable-object identity.
The owner returns opaque handles carrying enough scope to reject cross-owner use.

Creating a participant may install its explicitly selected type registrations,
but must not create its topics or endpoints. Creating a writer requires an existing
publisher and the intended topic in the same participant instance. A missing
dependency is an error, not an instruction to build it automatically. Repeated
XRCE CREATE behavior belongs to the adapter, not the construction primitive.

Extract common entity creation/QoS/cleanup helpers from whole-graph construction.
Keep `Instance.build` working through those helpers. Do not implement repeated
CREATE by constructing overlapping whole graphs or rebuilding an existing graph.
Retain cleanup ownership after rollback/deletion errors. Block new operations on
an owner being cleaned up; do not hold builder locks across DDS/provider callbacks.

Add an explicit endpoint representation enum, with the existing XCDR1 default.
Carry it through generated resource authoring, profile resolution, inspection and
provider capability checks. Require the selected representation rather than
unconditionally requiring XCDR1. The agent's initial standard sample path selects
XCDR2. It must reject an incompatible provider before entity construction. Do not
convert samples between XCDR versions or infer a representation from their contents.

Future agent configuration should allow a default DDS encoding and per-topic or
endpoint overrides. Direct forwarding initially accepts only XCDR2. Supporting an
XCDR1 destination requires explicit sample conversion; reject that configuration
until conversion exists. Keep the shared builder's representation choice general
so this later agent policy does not require another resource model.

An incremental writer needs a checked write operation using its retained type
selection. `Prepared.write` currently accepts a whole-graph Instance: extend the
shared support rather than bypassing validation through raw writes. Returning a
writer handle alone is insufficient to express ownership of the checked write path.

## Agent configuration and request boundary

Use the existing shared resource authoring and provider input mechanisms. Add a
small agent-owned reference mapping from public names to resource definitions,
allowed parent definitions and permitted settings. Do not create another QoS/profile
parser or put native library paths into portable TOML. Configuration is immutable
for this slice; hot reload is deferred.

A process owns loaded providers and prepared definitions. Each client owns a
separate incremental graph and XRCE association table. An association records the
normalized definition/settings, parent association and selected type generation.
It is inserted only after construction succeeds. Reserve capacity first so that
committing a successful backend result cannot fail due to table allocation.

Client storage must have stable addresses once it owns a graph. The current
construct-a-local-Agent-then-copy-into-slot pattern must not copy owning values or
leave callback contexts pointing at stack temporaries. Templates contain borrowed
configuration only. Shutdown releases client entities before prepared bindings,
provider manager, factory and allocator; deferred DDS reclamation must finish before
those allocators disappear.

Initially authorize a concrete participant domain and require CREATE to agree.
Resolve parent IDs within the same client and check kind, definition and ownership.
For a writer, resolve its named topic in that participant instance, not globally.
Normalize defaults before comparing REUSE; an equivalent request keeps its existing
type generation even if a provider alias has since changed. Conflicting replacement
and parent deletion with dependents are outside the initial supported subset; return
an explicit error without deleting anything. Leaf deletion removes the XRCE mapping
only after DDS cleanup succeeds. Retain a retryable owner for partial cleanup.

Before backend work, ensure reply capacity for supported STATUS-producing operations.
A short output buffer must not accidentally cause a successful operation to be
replayed as a new construction attempt. Network loss still requires the documented
REUSE/session behavior; it does not imply exactly-once stream processing.

## Protocol audit and selected subset

Sources: [DDS-XRCE 1.0](https://www.omg.org/spec/DDS-XRCE/1.0/PDF),
[normative IDL](https://www.omg.org/spec/DDS-XRCE/20190301/dds_xrce_types.idl),
and the existing [interop audit](../interop/spec-audit.md).
The published prose and IDL have known inconsistencies; retain the existing explicit
OMG/eProsima login distinction. Recheck exact wire fixtures before adding decoders.

| Operation | First backend subset |
| --- | --- |
| Participant and topic CREATE | Authorized by-reference definitions |
| Publisher CREATE | Bounded standard binary representation; optional name must select an allowed configured publisher; absent name only when selection is unambiguous |
| Writer CREATE | Bounded standard binary representation; topic name selects an allowed configured writer under that publisher; ambiguous selection rejected |
| Binary QoS | Initially absent; reject supplied unsupported policy rather than silently dropping it |
| WRITE_DATA | Little-endian FORMAT_DATA, one XCDR2 sample, exact length validated by its selected provider |
| Leaf DELETE | Writer, then empty containers/topics/participant in dependency order |
| Client lifecycle | Explicit cleanup on changed session, deletion, RESET and shutdown; same-session login preserves ownership |

The IDL distinguishes participant/topic forms from publisher/writer binary/XML
forms. By-reference publisher/writer and empty publisher XML remain compatibility
extensions. Same-key/same-session login preserves state; a changed session replaces
it (§7.8.2.1). RESET resets session state (§8.3.5.13). CREATE flags follow Table 5;
unsupported replacement remains a declared limitation. DELETE and WRITE return
correlated STATUS (§8.3.5.4, §8.3.5.8). CREATE's disabled-entity/discovery requirement
(§7.8.3.1) needs separate backend qualification; local rollback does not establish it.

Do not broaden shared `DecodedCreate.reference` to mean binary bytes. Add a tagged
representation in zz0_client, preserving its existing public convenience APIs where
possible. Decode bounded binary records with the existing XCDR infrastructure,
including appendable/optional-member rules. Author hand-checked wire fixtures and
run an independent client; an encode/decode round trip is insufficient evidence.
The IDL's writer QoS annotation contains a typo; record the interpretation alongside
the decoder fixture rather than silently treating generated output as authoritative.

The initial dispatch error policy is provisional until checked against each
operation's specification table: missing object/reference -> unknown reference;
wrong parent or conflicting REUSE -> mismatch; denied catalog selection -> denied;
malformed sample/unsupported request fields -> invalid data; exhausted budgets ->
resources; DDS construction or cleanup failure -> DDS error. Keep the original
backend error in local diagnostics. Test CREATE's complete flag truth table: in
particular, both flags clear must return already-exists for any occupied ID.

WRITE success is backend acceptance, not subscriber receipt. Maintain separate
received/rejected/backend-accepted counters. Optional CounterStatus telemetry runs
after acceptance and cannot reverse that result. Choose telemetry by configured
type/definition, not the numeric object ID. Compatibility validation can retain its
existing behavior until explicitly migrated; backend startup failure must never
silently fall back to local-only acceptance.

## Implementation order and evidence

1. Add explicit representation selection and incremental construction in zzdds.
   Test no eager siblings, two instances, cross-owner handles, missing dependencies,
   allocation failures, callback cancellation, leaf deletion and retryable rollback.
2. Add the agent's backend boundary, client-owned graph and catalog mapping. Use a
   fake backend to exercise request/status behavior and failure paths before enabling
   real forwarding. Keep existing demo/independent interop tests running.
3. Extend zz0_client codecs for the selected binary CREATE and lifecycle messages.
   Add externally checked wire fixtures and bounds/truncation/unsupported-QoS cases.
4. Wire the pinned zzdds dependency, provider startup and checked XCDR2 writes.
   Prove two clients using the same IDs create independent DDS objects. Test repeat
   login, changed session, RESET, deletion and shutdown before enabling this path
   for production use.
5. Run publishing acceptance: multiple providers/types, malformed input, independent
   DDS subscriber, reconnect/failure injection, then both Pico boards. This is slice
   5 evidence, not a claim made by unit tests or a successful WRITE status.

No release is required to start these steps. Do not merge changes into concurrent
runtime/broker work: keep shared changes in resources/typesupport APIs and use public
DDS operations. Reassess if current main changes their lifetime contracts.

## Questions to settle during implementation

- Binary CREATE encoding fixtures and status mappings need the operation-by-operation
  audit above; this is engineering work, not a request for a new user-facing format.
- Confirm disabled creation and deferred allocator retirement against the selected
  zzdds pin. Record unsupported guarantees honestly if backend APIs cannot supply them.
- Parent cascades, live REPLACE, reliable streams, bidirectional traffic and provider
  reload remain later work. Do not accidentally advertise them through this subset.

There is no product-direction question blocking the first shared-library step.

## Modern encoding and Pico consumer (2026-10-30)

The user selected XTypes 1.3 XCDR2 explicitly for protocol and sample encoding,
aligned with zzdds. Historical 1.2 decoding is outside the initial scope; no future
OMG revision is assumed. Expand to 1.4 after formal publication and review. Generated
appendable, nested and mutable fixtures supplement the final CounterStatus tests.

The Pico demo now includes `dds-consumer/`: a small host zzdds application reading
CounterStatus, with domain/topic/type/board selection and bounded count/timeout.
It has a host fixture publisher for DDS smoke testing. This tool supports manual
Pico diagnostics and future scripted acceptance. The complete publishing test is
still Pico or independent XRCE client -> real agent backend -> this consumer,
followed by an independent DDS subscriber to avoid relying only on our own stack.
Do not count a host DDS smoke test as completed agent/hardware forwarding.

## Real adapter and managed sessions (2026-10-30)

Items 2–3 are implemented locally: see [real backend evidence](real-dds-backend.md).
The agent uses published zzdds 0.3.11 and one shared zidl 0.3.27 runtime. The
`zidl_typesupport` module export supplies the ABI for generated providers. The
configured executable forwards through DDS; the older compatibility fixture lives
in `zz0_agent_compat` and retains `--validate-only`.
The Pico CREATE path uses standard binary publisher/writer records and is covered
by a native backend test. Pico hardware acceptance is recorded above. General
CLI provider/catalog startup is covered by the follow-on checkpoint below;
vendor-independent forwarding qualification remains subsequent work.


## Configured startup follow-on (2026-11-11)

The [configured startup design](configurable-startup-plan.md) is implemented locally:
normal builds require explicit configuration/library inputs and no longer depend
on the Pico repository. Offline validation, loaded inspection, shared profiles,
explicit multi-provider selection and checked startup/shutdown are qualified in
Debug, ReleaseSafe and host TSan. CounterStatus and legacy CREATE conventions are
explicit fixture content. The operator reports the configured Pico acceptance
passed with the previous firmware images; see [the result](pico-acceptance.md#operator-reported-result-2026-11-11).
