# Independent XRCE interoperability

This host-only test drives `zz0_agent_compat` with eProsima Micro XRCE-DDS Client v3.0.1.
All request framing and sample CDR come from the upstream C SDK and Micro-CDR.

It checks session login; by-reference participant, topic and writer creation;
empty-XML publisher creation; unknown-reference rejection; and plain CDR
CounterStatus acceptance. Both the client status and the agent's decoded fields
`{counter=42, board="eprosima", payload length=3}` are asserted. A truncated
sample must return ERR_INVALID_DATA without a second successful write.

With sibling `zz0_client` and `zz0-pico-demo` checkouts, Zig 0.17.0, CMake and
a C compiler, run from this repository on Linux:

```sh
python3 interop/build_peers.py --work /tmp/zz0-agent-peers
zig build fixtures -Doptimize=ReleaseSafe
python3 interop/run.py --agent zig-out/bin/zz0_agent_compat \
  --prefix /tmp/zz0-agent-peers/install --logs /tmp/zz0-agent-interop
```

The exact upstream client and Micro-CDR revisions are pinned in `build_peers.py`.
They are built without source patches and outside the repo. CI caches the build
by script hash, runs Debug/ReleaseSafe unit tests and this live test, and uploads
logs even after failure. The agent uses an ephemeral UDP port, leaving the Pico
agent on port 8888 alone. Tests require real localhost UDP sockets. All child
processes have deadlines and are stopped on success or failure.

CI pins the companion zz0_client checkout to commit
`9ffef195bcac18d4695ef5f7a9c58a5bf9beab85` (PR #2: binary CREATE and lifecycle codecs).
Manual dispatch accepts `client_ref` to test another branch, tag or commit;
leaving it empty uses the pin. The demo checkout supplies only the existing
CounterStatus IDL to the agent build; firmware is not needed for the interop test.

This tests local acceptance, not DDS delivery. The runner explicitly selects the compatibility executable with
`--validate-only --handshake=eprosima_v3`; the configured normal agent forwards through DDS
and expects standard binary publisher/writer CREATEs. The test uses individual
requests over a best-effort stream, no properties,
keyless session headers, little-endian CDR and bounded, unfragmented packets.
It does not establish reliable-stream, multi-operation-datagram, deletion,
subscription, authentication or general XRCE conformance. The eProsima empty-XML convention
is the only XML creation form accepted; arbitrary XML profiles are unsupported.
Both empty XML and the existing by-reference publisher are demo compatibility
forms, not standard publisher XML/binary support.

## Wire correction affecting the Pico demo

XRCE sample bytes now use plain CDR, without a DDS encapsulation header. The
companion Pico serializer was updated together with this agent; rebuild/reflash
it when switching to this agent. Legacy encapsulated samples are not guessed
from their first bytes, which could equally be a valid counter value. On
2026-10-20 the operator confirmed both reflashed boards passed simultaneous
decoded publishing, agent-restart recovery and WiFi reconnect recovery against
the updated agent.

## Normative audit

See [spec-audit.md](spec-audit.md). Normal operation defaults to
`--handshake=omg_1_0`; only the explicitly selected eProsima mode adds MTU/result
fields. The published OMG STATUS_AGENT IDL has no result field.

The Pico firmware uses a separate standard CREATE helper: participant/topic
references, then modern XTypes 1.3 binary publisher/writer records. This pinned
eProsima compatibility fixture deliberately retains its vendor CREATE forms.
Its binary writer API instead takes a topic object ID and includes QoS; it is
not a drop-in replacement for our topic-name binary subset. These fixtures do
not require the firmware or real DDS backend to accept the vendor extensions.

## Configured startup checks

`zig build test-startup` builds the normal agent and an explicit generated provider,
then runs `startup.py` against offline validation, loaded inspection, file/identity
constraints, relative path bases and failed UDP bind rollback. Its offline-only
mode runs without a Pico checkout or a provider artifact:

```sh
zig build
python3 interop/startup.py --agent zig-out/bin/zz0_agent \
  --config examples/counter/agent.toml --offline-only
```

The [DDS forwarding smoke test](../docs/real-dds-backend.md#evidence) uses the normal
executable with an explicit configuration and library. The independent eProsima
fixture above remains a validation-only protocol test.

## Multiple project libraries

```sh
zig build test-multi-library
# Also run in CI:
zig build test-multi-library -Doptimize=ReleaseSafe
zig build test-multi-library -Dsanitize-thread=true
```

This lane generates three separate libraries from agent-owned fixture IDL, using
the published zzdds/zidl dependency graph; it needs no Pico checkout. Normal builds
and core tests do not generate these providers. Logs default to
`.zig-cache/multi-library-logs`; override with `-Dmulti-library-logs=PATH`.

Project A and B supply distinct selected types, equivalent `Common::Reading`
exports and conflicting `Common::Unused` exports. A third library supplies a
conflicting `Common::Reading`. Checks establish that explicit selections survive
reversed load order; equivalent exports have equal Minimal TypeIdentifiers;
a constrained conflicting selection, duplicate binding and missing export fail
before readiness. Unselected conflicts do not cause global type registration.
An explicitly chosen different definition without an identity constraint is valid;
there is no automatic winner, assignability check or implicit replacement.

Two XRCE clients then reuse the same object IDs through one configured normal
agent. A separate DDS consumer process verifies all three selected types from both
clients, initially, after RESET, after reconnect and after idle expiry/recreation
(24 distinct receipts). With a five-second test timeout, one client keeps writing
while the other expires; same-key/session login then requires a fresh graph.
The active client retains its graph. The test checks malformed/trailing
samples, resource names that have no public XRCE reference, repeated REUSE/login,
client deletion and normal shutdown with another client's graph still live.
The consumer loads the same provider selections, creates only its own readers and
decodes sample fields through the CDR reader without linked generated sample types.
These are Linux tests using our DDS implementation in both processes, rather than
independent-vendor DDS interoperability or physical-board evidence.

See [the Pico acceptance commands](../docs/pico-acceptance.md) for the completed
configured-startup hardware record and the pending short-timeout expiry check.
