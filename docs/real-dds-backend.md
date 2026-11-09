# Local real-DDS backend checkpoint

2026-10-30. The real adapter and managed UDP client ownership are implemented
locally. The default executable path forwards CounterStatus into DDS; `--validate-only`
selects the older compatibility fixture without forwarding.
Neither mode is a claim of full XRCE conformance.

## Shared code and dependency

`dds_backend.Context` owns a lazy, bounded zzdds Incremental graph. Its Backend
callbacks create only the requested resource, write through Prepared's checked
provider path, delete leaves and retain failed cleanup for retry. `clear` allocates
nothing: it destroys the old graph and initializes another only on a future CREATE.

`Runtime` validates catalog names, parent/topic references, concrete domains and
endpoint XCDR2 support against an immutable provider preparation before admitting
clients. Each client has a separate stable heap allocation containing its graph
context and association owner. The preparation, catalog, allocator and caller-owned
DDS factory outlive all client cleanup. Runtime deinit rejects live clients.

The loadable-library prototype currently supports bounded final types. The real
adapter therefore requires plain XCDR2 encoding and wire-validation-capable provider
bindings. Generated appendable/mutable packet tests do not extend that library ABI.
The adapter is type-agnostic within the provider subset; CounterStatus appears only
in the built-in startup configuration and optional telemetry selection.

The agent and Pico DDS consumer pin published zzdds **0.3.11**, including
incremental construction, explicit endpoint representation, provider ABI exports,
and logical handle retirement. Generation, telemetry and provider callbacks all
use its zidl **0.3.27** dependency, sharing one runtime module. A sibling zzdds
checkout is no longer required. Hosted CI pins zz0_client PR #2's merged commit,
`9ffef195bcac18d4695ef5f7a9c58a5bf9beab85`, for binary CREATE and lifecycle codecs.

## Sessions and cleanup

The managed UDP registry allocates a fresh backend for each client key. Client IDs
and DDS graphs remain separate when clients use identical XRCE object IDs.

- Same key/session preserves resources, provider generation and counters. The UDP
  peer may rebind; the old peer then no longer routes to that client.
- Changed session closes the old owner before installing the new one. Failed close
  retains and blocks it for retry. If new allocation fails after successful close,
  the old session remains removed; replacement is not an atomic transaction.
- RESET clears that client's graph while retaining its registry slot/context.
- DELETE of the ProxyClient clears/frees its owner and releases its slot. Failed
  deletion returns a correlated error STATUS and retains the owner for retry.
- Checked server/session close releases clients before the preparation/factory.
  Failure retains the server/socket and surviving slots. Callers must retry before
  freeing those dependencies. The `close` API is now fallible for this reason.

Status reply capacity is checked before CREATE, WRITE, DELETE or replacement
side effects. A published-layout login failure has no fabricated STATUS_AGENT error
field; invalid/rejected login remains an internal error/drop. Stream ordering,
reliable transport, idle expiry, authentication and parent cascade/replacement
remain outside this subset.

## Executable fixture

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zz0_agent --port=8888 --write-log=summary
```

The built-in configuration uses DDS domain 0, topic `CounterStatusTopic`, type
`CounterStatus`, publisher definition `pub`, and the existing MyLibrary reference
names for participants/topics. Publisher/writer CREATE uses the modern binary
subset; legacy by-reference publisher/writer and empty XML are not enabled here.
Pico firmware now sends this standard CREATE sequence. A native integration test
checks the exact firmware helper, repeated REUSE requests, and a checked DDS write.
Both-board forwarding and recovery have operator-reported hardware evidence;
see the evidence section below.

This is a bounded publishing fixture: the graph capacity is 32 and endpoint limits
are 256 samples/instances, with KEEP_LAST depth 1. Long-running applications need
appropriate configuration and instance lifecycle; CounterStatus's counter is its
key. DDS exhaustion maps to XRCE ERR_RESOURCES. General CLI provider paths, resource
TOML and catalog authoring remain later startup integration; programmatic adapters
already accept prepared provider bindings and a validated catalog.

For deterministic shutdown tests, `--max-datagrams=N` exits the serve loop normally
after N datagrams and runs checked cleanup. Normal OS signal handling is unchanged;
this fixture does not add a graceful SIGTERM protocol.

## Evidence

Release-pin recheck (2026-11-09): agent and consumer use published zzdds 0.3.11
and its zidl 0.3.27 dependency.

- Debug/ReleaseSafe: 45 agent tests pass, including the exact Pico CREATE helper.
- LLVM-backed ThreadSanitizer: all 45 tests pass with `-Dsanitize-thread=true`.
  Both the test and executable builds explicitly select LLVM when enabled.
- The companion client passes all 29 tests in Debug and ReleaseSafe.
- The pinned eProsima client passes its validation-only compatibility test. This
  checks independent XRCE request/sample acceptance, not vendor DDS forwarding.
- Native DDS tests exercise two clients, sample receipt, malformed samples, REUSE,
  repeat login, peer rebinding, changed sessions, RESET, ProxyClient deletion,
  capacity/allocation failures, retained failed cleanup and retry.
- A separate-process host smoke client sends XRCE over UDP to the real agent,
  and the Pico DDS consumer decodes three board/counter/payload samples. RESET, client
  deletion and bounded normal agent shutdown finish successfully. This check was
  repeated against the published dependency pin on 2026-11-09.

Run the smoke test after building the sibling consumer:

```sh
python3 interop/dds_smoke.py --agent zig-out/bin/zz0_agent \
  --consumer ../zz0-pico-demo/dds-consumer/zig-out/bin/counter-consumer \
  --logs /tmp/agent-dds-smoke
```

The test uses modern hand-authored XRCE records and checks correlated STATUS, then
actual consumer receipt. It keeps publishing through discovery instead of assuming
WRITE acceptance or a short startup sleep guarantees a reader match. It uses our
own DDS stack at both ends; an independent vendor subscriber/client, full startup
configuration, longer soak tests and hardware malformed-data injection remain
separate work. These automated results are local Linux qualification only.


## Operator-reported hardware evidence (2026-11-04)

Pico WH and Pico 2 WH both forwarded through the default agent to separate
board-filtered DDS consumers. Each consumer received 10 samples and exited
successfully for simultaneous publishing, agent restart, a Pico WH reset while
Pico 2 WH stayed running, and access-point loss/restoration. After agent restart,
both boards retained high counters; after the Pico WH reset its counter restarted
at 1 while Pico 2 WH retained high counters. Consumers in the initial trial joined
after the boards were already publishing.

See [the consumer's detailed record](../../zz0-pico-demo/dds-consumer/README.md#hardware-results-2026-11-04).
These observations were reported by the operator; raw logs were not supplied.
They verify bounded DDS receipt and recovery using our stack, rather than just
local sample acceptance. Longer soak tests, the reverse board-reset scenario and
independent-vendor interoperability remain unqualified.
