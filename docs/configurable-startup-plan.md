# Configurable agent startup

Design checkpoint: 2026-11-09. Proposed next work after the merged DDS backend
and Pico forwarding changes. This document describes intended behavior, not
features already available in the executable.

## Result we want

A normal agent loads several independently generated typesupport libraries,
selects the types its configuration needs, and lets XRCE clients construct their
own DDS resources from those definitions. Adding a project does not rebuild the
agent. A library may export many types; only explicitly selected types enter the
resource plan. CounterStatus becomes an ordinary example using this same path.

Keep the publishing subset, per-client ownership and retryable cleanup already
implemented. Keep modern XTypes 1.3, little-endian plain XCDR2 for direct forwarding.
Hot reload, type assignability, new QoS policies, DDS-to-XRCE delivery, reliable
XRCE streams and general XML/JSON import are separate work.

## Reuse the existing pieces

| Concern | Owner and existing implementation |
| --- | --- |
| Generated type descriptors and wire callbacks | zidl's loadable-library C ABI |
| Loading several libraries and retaining their code | zzdds `typesupport.Manager` and `resources.providers.Environment` |
| DDS resources, QoS, defaults and named profiles | zzdds `resources.authoring.parse` and `Parsed.resolve` |
| Selecting exact exports and checking capabilities | zzdds `resources.providers.validate` and `Prepared.init` |
| Creating requested entities and checked writes | zzdds `resources.Incremental` and `Prepared.writeIncremental` |
| Strict record decoding, optional settings and source locations | zidl-generated configuration records over zzdds's TOML parser |
| XRCE public reference names and request authorization | Small agent-owned manifest, resolved into `backend.Catalog` |

The baseline is zzdds 0.3.11 and its zidl 0.3.27 dependency. Keep one shared
runtime/module graph. Enable `resource-authoring` in the hosted agent build.
No new shared-library contract or alternative DDS builder is expected. If an
implementation needs a missing common helper, propose that small shared change
separately rather than copying its semantics into the agent.

This follows the earlier zzest split: reusable DDS definitions remain in zzdds;
process-specific orchestration remains in its caller. Future DDS-XML/JSON adapters
can produce the same resource plan without teaching this manifest about DDS QoS.
Existing zzdds process/factory configuration stays on its existing resolver path;
this slice does not introduce another representation of those settings.

## Three explicit startup inputs

1. **Resource TOML:** the existing portable zzdds application/profile document.
2. **Agent manifest:** the resource file, exact provider selections, and public
   XRCE reference mappings. It contains no DDS QoS definitions or client IDs.
3. **Library arguments:** repeatable `--library alias=path` arguments supplied by
   the operator. Paths stay outside portable resource definitions.

Proposed command:

```sh
zz0_agent --config ./counter-agent.toml \
  --library counter=./providers/libcounter_types.so \
  --port=8888 --write-log=summary
```

Several projects use several arguments, for example `--library project_a=...`
and `--library project_b=...`. Those aliases select libraries, not DDS entities.
There is no directory scan, automatic export registration or load-order winner.
Use the platform's actual shared-library artifact, not a hardcoded `.so` rule.

`--config` is required for serving. With no configuration, report usage and exit
before creating the DDS factory or binding UDP. Keep `--help` and `--version`
available without configuration. A startup failure never falls back to the old
validation-only behavior.

Keep the existing generic network/logging flags. CLI values remain explicit
process options; they do not rewrite resource QoS. Bindings live in the manifest
initially; a second CLI spelling for each binding is unnecessary for the first
slice. Library locations remain easy to supply from the command line.

### Resource document

`counter-resources.toml` uses the existing zzdds schema unchanged:

```toml
schema_version = 1
name = "CounterStatus"

[profiles.XRCE.writer_qos]
data_representation = "XCDR2"
max_samples = 256
max_instances = 256
max_samples_per_instance = 256

[participants.main]
domain_id = 0
types = { CounterStatus = {} }
topics = { counter = { topic_name = "CounterStatusTopic", type_ref = "CounterStatus" } }
publishers = { pub = {} }

[participants.main.writers.counter]
container_ref = "pub"
topic_ref = "counter"
profile_ref = "XRCE"
```

Use the shared base-profile -> derived-profile -> endpoint resolution and its
existing concrete defaults. In particular, omitted representation still means
XCDR1 in the shared schema. An exposed forwarding writer must explicitly resolve
to XCDR2; the agent must not silently change that default. An eventual encoding
conversion feature can extend this policy without changing the resource model.

### Agent manifest

Proposed `counter-agent.toml`:

```toml
schema_version = 1
resources = "counter-resources.toml"

[[bindings]]
participant = "main"
type_name = "CounterStatus"
provider = "counter"

[catalog."MyLibrary::CounterParticipant"]
kind = "participant"
participant = "main"
resource = "main"

[catalog."MyLibrary::CounterStatusTopic"]
kind = "topic"
participant = "main"
resource = "counter"
parent = "MyLibrary::CounterParticipant"

[catalog."MyLibrary::CounterPublisher"]
kind = "publisher"
participant = "main"
resource = "pub"
parent = "MyLibrary::CounterParticipant"

[catalog."MyLibrary::CounterStatusWriter"]
kind = "datawriter"
participant = "main"
resource = "counter"
parent = "MyLibrary::CounterPublisher"
topic = "MyLibrary::CounterStatusTopic"
```

Generate the manifest's records from agent-owned configuration IDL using
`--zig-generate-authoring`. Parse with `dds.toml.parseOwned` and the shared strict
decoder. Do not hand-code another TOML parser, QoS decoder or profile resolver.
`bindings` is an array of records; `catalog` is a named collection whose key supplies
its public `name`, using the existing decoder convention.

The resource path is relative to the manifest's directory. CLI library paths are
relative to the invocation's working directory, matching resource-inspect. Resolve
those bases explicitly to absolute paths before calling `Environment.init`.
There are no recursive includes, environment expansion or network imports.

Each binding selects the exact export named by `type_name` from its provider.
The registered DDS name must match the export name; type renaming is unsupported.
Several entries may select different exports from one library. Every type declared
in the resource plan needs one binding, as required by `providers.validate`;
exports absent from the plan need no binding. Unused library exports remain unused.
Duplicate bindings or provider aliases are errors, even if their contents agree.

Allow optional `expected_identifier` on a binding (the existing 15-byte Minimal
TypeIdentifier, authored as 30 hex digits) and `--sha256 alias=64-hex-digits` for
artifact constraints, matching the shared inspection example. Reject malformed,
duplicate or unknown constraints before loading. No implicit content trust or
identity-by-filename is introduced.

Manifest syntax is versioned independently of resource syntax. Unknown ordinary
fields are errors. Support the shared `_setting` convention for optional settings:
unknown settings are reported as skipped, while known invalid values still fail.
Catalog names starting with `_` are literal names, not conditional settings.

## Resolve references without duplicating DDS facts

The catalog is an explicit list of what clients may request. A resource definition
not exported there is not automatically available to XRCE. Public reference names
are distinct from DDS topic names and provider aliases.

Resolve each catalog entry against the shared plan before loading any library:

- Check the supported publishing kinds: participant, topic, publisher and writer.
- Check that each resource exists in its named participant.
- Check public parent/topic references against the resource graph, including scope.
- Derive participant domain, DDS topic name and writer encoding from the plan.
  Do not ask users to repeat these in the manifest.
- Named binary publishers select the configured publisher resource. Distinct
  publisher names are valid; unnamed requests need a unique match at request time.
  Reject duplicate aliases for the same publisher under one public participant.
  Reject ambiguous binary writer choices. Until clients have another
  supported discriminator, two exported writers under one public publisher cannot
  both match the same DDS topic name. Ambiguity within a client's live topic
  instances remains a request-time error under the existing rules.

Convert the result to the existing immutable `backend.Catalog`. Keep XRCE object
IDs, REUSE comparison, session state and native entities out of the configuration.
The same configuration can serve clients with overlapping object IDs, each with
its own empty incremental owner. Loading a resource document does not construct
its whole DDS graph or create its unrequested audit readers/endpoints.

## Startup checks and execution order

Provide three clear operations over the same inputs:

| Operation | Work performed |
| --- | --- |
| `--check-config` | Parse both files, resolve profiles/resources/catalog, check explicit bindings and alias constraints. No library file access or provider code. Report that ABI, export identity and wire capabilities remain unchecked. |
| `--inspect` | Perform the above, then load libraries and prepare selections. Print resolved definitions, provider generations, hashes and capabilities. The host creates no DDS factory or UDP listener. |
| Normal serving | Perform full inspection-level validation, create the factory/runtime, and bind UDP last. Print readiness only after every stage succeeds. |

Offline checks may accept library paths that do not exist. Full preparation must
check every declared type's binding and provider ABI/capabilities. Every XRCE write
requires provider-backed exact wire validation; a compiled adapter without that
capability is not a substitute. Reject incompatible ABI/capabilities and retain
the current generated bounded-final library subset. The generator rejects other
type shapes; the loader's structural/hash checks are not an independent semantic
TypeObject parser. Do not infer extensibility from an XCDR2 capability bit or
encoding from incoming sample contents. Supporting broader providers would need
an explicit contract review, not a silent plain-CDR2 assumption.

Use `Environment.init` to preflight all artifact paths/hashes before loading any
provider, followed by `Prepared.init` and the catalog's prepared-capability check.
Loading is trusted native-code execution even in inspection mode. Hashes and type
identifiers provide different checks: file provenance versus standard type identity.
Neither introduces CompleteTypeObject equivalence or assignability. An equivalent
export still requires an explicit provider choice; conflicting same-name types in
one participant fail rather than replacing an earlier registration.

Diagnostics retain file, line/column and field for manifest/resource errors.
Provider errors identify the alias, artifact and selected participant/type.
Inspection reports resolved values, inherited profile provenance, skipped optional
settings and immutable provider selections. Do not label an offline check as
provider qualification. Reuse shared limits: 256 KiB per TOML document, a 1,024
resource/profile budget, 1,024 bindings, 32 provider inputs and 64 MiB per artifact. Keep the current
128-entry catalog, eight-client bound and 32-slot per-client graph. UDP datagrams
are bounded to 512 bytes including XRCE headers; the backend separately caps the
serialized sample body at 512 bytes. Changing these budgets is separate work. Check per-client resource
capacity as clients construct objects, not by equating total template count with
live object count.

## Ownership and shutdown

Keep an owned startup object at a stable address. It retains configuration strings,
the resolved catalog, `Environment` and `Prepared`. Do not copy it after backend
contexts borrow its addresses. Use a thread-safe, long-lived allocator for the environment and prepared owners;
the parsed-configuration arena is for immutable configuration text, not backing
storage that deferred DDS/provider releases might still need.

On startup errors, unwind only initialized owners in reverse order. On shutdown:

1. Stop admitting/receiving client traffic and close client graphs through checked
   server cleanup. A failed close retains the owners needed for retry.
2. Finish the agent runtime after all client owners have closed.
3. Destroy the DDS factory and finish its deferred work while provider allocations
   and callbacks are still valid.
4. Release prepared selections, then the library environment, then configuration
   storage/allocators and I/O support.

Do not unload a library merely because the last XRCE association was removed.
Use the shared registration and generation pins, including deferred native users.
No watcher, SIGHUP reload, artifact overwrite or live alias replacement is exposed.
Those later features can build on zzdds's existing generation-aware contract.
Slice 3 must verify the factory/deferred-work completion boundary at the selected
release before releasing provider allocation storage; logical entity deletion
alone is not evidence of completion.

## Remove CounterStatus from the ordinary build

Before slice 1, the dependency was wider than `dds_demo.zig`: build.zig generated the type
and provider from the Pico checkout; root.zig imported its decoder/statistics;
backend.Definition carried a CounterStatus telemetry choice; resources.zig supplied
a default demo reference catalog; and validation-only tests depended on those facts.
Remove all of those assumptions from the generic build, not just the startup branch.

- The production executable has no CounterStatus type, hardcoded catalog, typed
  decoder, fixed demo object IDs, or dependency on the Pico repository.
- Generic logs retain request/client/type selection, acceptance counts and bounded
  byte output. Decoded CounterStatus fields are verified by the consumer.
- Move CounterStatus IDL generation and its shared library into an explicit fixture
  build, for example `test-fixtures` / `-Dtest-fixtures=true`. Build that library as
  a separate artifact; do not link its provider into the production executable.
- The Pico example runs the normal executable with the two configuration files
  and its generated library. Move its exact current catalog strings into those
  files, so firmware requests retain their existing meaning.
- Move the old `--validate-only` reference/empty-XML compatibility fixture and typed
  telemetry into a separate opt-in test executable. It may reuse the protocol
  engine through explicit fixture policy/backend injection; it must not establish
  a new built-in fallback or a second protocol implementation.
- Keep the existing explicit eProsima login encoding available where needed. Moving
  the validation fixture does not imply changing that established wire option.

Normal `zig build` and `zig build test` must work with no Pico checkout and no
sample-type generation. Default tests cover generic protocol/backend/configuration
behavior. Fixture integration jobs still run on ordinary pull requests; opt-in
build content does not mean optional CI coverage. Reassign every existing
CounterStatus-dependent test to the appropriate lane rather than dropping it.

## Implementation slices and acceptance

1. **Generic core and fixture boundary.** Extract sample-independent protocol and
   backend code, move typed/compatibility behavior into explicit fixtures, and
   prove that the generic target builds without the Pico checkout. Retain the
   existing executable behavior until configured serving is ready for cutover.
2. **Configuration resolution.** Add the generated agent manifest records, shared
   resource parsing, explicit binding conversion and catalog resolution. Test
   defaults, profile overrides, `_setting`, precise errors, paths and limits without
   opening providers or constructing DDS entities.
3. **Library-backed startup.** Wire `Environment`, `Prepared`, inspection and serving
   with stable ownership and UDP last. Test startup rollback, bounded resources,
   capability failures and shutdown; retain existing per-client cleanup semantics.
   Switch normal build/CLI defaults only when the explicit CounterStatus resource
   files/library and compatibility fixture are ready in the same change.
4. **Multi-project and Pico qualification.** Run at least two independently generated
   libraries with distinct selected types through one generic agent. Check real DDS
   receipt, overlapping client IDs, unselected exports, explicit equivalent/conflicting
   names, malformed samples, RESET, reconnect and cleanup. Migrate Pico instructions
   and repeat the configured CounterStatus forwarding smoke and board acceptance.

CI should have a sample-independent core job, a multi-library configured-startup
job and a CounterStatus/Pico integration job. The latter generates its provider
and configuration explicitly and uses the normal agent executable; the legacy
vendor fixture is a separate explicit compatibility test. Build/invoke paths must
exercise the published zzdds/zidl module graph. Keep Linux LLVM TSan qualification
for the host; retain the existing uninstrumented-DSO constraint for generated
provider fixtures. The shared loader already has macOS/Windows backends: preserve
portable paths and capability errors, but do not claim native agent qualification
until its startup and packet paths actually run there.

Each slice should be reviewable without publishing an agent that has lost its
working forwarding path. The final sample-independent build contract above is
the cutover acceptance criterion, not a reason to leave an intermediate default
executable unable to serve.

## Design checks performed

Both TOML examples pass TOML syntax parsing. The resource example also passes the
actual zzdds 0.3.11 `resource-inspect validate` and `plan` commands with a deliberately
nonexistent library path. The resolved writer is XCDR2, best-effort, depth 1, with
256 samples/instances/per-instance; offline validation reports provider checks as
incomplete. The manifest schema and agent CLI are now implemented; see the slice
checkpoints below for current qualification.

No new product decision blocks slice 1. This plan needs implementation review,
not a separate dependency release or expansion of the loadable ABI.

## Slice 1 checkpoint

The public core module now contains sample-independent protocol, UDP and DDS
backend code. CounterStatus decoding, demo catalogs, provider generation and legacy
acceptance behavior live behind the explicit fixture module. During slice 1, the existing executable used that module to preserve its CLI and
forwarding behavior until the slice 3 cutover.

`zig build test` runs core regressions without a Pico checkout; CI has a separate
core job. `zig build test-fixtures` retains the sample and compatibility tests,
including real DDS forwarding, and runs in its own CI job. Both jobs qualify Debug,
ReleaseSafe and LLVM TSan. Offline configuration resolution is covered by the
slice 2 checkpoint below; configured library loading and the executable cutover
are covered by the slice 3 checkpoint below.

## Slice 2 checkpoint

`idl/agent_config.idl` generates strict manifest records with the pinned zidl.
The public `config.parse` accepts an absolute manifest filename and its bytes;
`Parsed.resourcePath` supplies the resource filename for the caller to read.
`Parsed.resolve` accepts resource bytes, an absolute invocation directory and
repeatable library/hash argument values. It performs no I/O and never loads a
provider or creates DDS entities. The CLI performs file reading and uses these same APIs (slice 3 below).

The result owns the shared resolved resource plan (including profile origins and
skipped resource settings), explicit provider bindings, absolute library paths,
hash constraints, immutable XRCE catalog and skipped manifest settings. It remains
valid after freeing the parsed manifest and input buffers. Diagnostics identify
manifest versus resource errors with source location/field; argument errors identify
the relevant `--library` or `--sha256` index.

Resolution checks scope and DDS graph relationships, derives domain/topic names,
requires exposed writers to resolve to XCDR2, rejects binary CREATE ambiguities and
marks their bindings as requiring provider wire validation. Plain CDR2 remains the
provisional encoding for the current bounded-final loadable-provider contract;
full preparation must verify that contract before serving. Offline success cannot
establish ABI compatibility, export identity, extensibility or provider capabilities.

Limits are 256 KiB per input document, 128 catalog entries, 1024 bindings and 32
library inputs/hash constraints, alongside shared parser and resource-plan limits.
Tests cover profile inheritance/overrides/defaults, optional settings, literal
underscore catalog names, multiple projects, invalid graph mappings, ambiguity,
identifiers/hashes, limits, diagnostic locations and allocation-failure cleanup.

## Slice 3 checkpoint

The normal `zz0_agent` executable now uses the generic core with required
`--config`, repeatable `--library` and optional `--sha256` inputs. It supports
`--check-config`, `--inspect`, `--help` and `--version`. Both valued-option forms
(`--flag value`, `--flag=value`) work. Offline checks do not access provider files;
inspection loads/checks providers without creating the DDS factory or UDP socket.
Serving validates preparations and catalog capabilities, creates the factory and
runtime, and binds UDP last. Readiness is printed only after binding succeeds.
Errors report source fields/locations or provider aliases, artifact paths and type
selections. Inspection includes profile origins, skipped settings and provider
identity/hash/generation/capabilities. No configuration failure invokes a fallback.

`Startup.open` allocates a stable host owner retaining Environment and Prepared;
it borrows immutable resolved configuration until checked close succeeds. The
executable uses libc storage for the host, provider generations, preparations and
client contexts. Configuration arenas do not back native/deferred provider work.
Failed construction unwinds initialized owners; failed client cleanup retains the
host, library environment, preparations, factory, runtime and socket for retry.
UDP bind failure retains a closable partial host. Normal bounded exit closes live
client graphs, runtime, factory, Prepared, Environment, then configuration storage.
Normal OS signal termination remains unchanged.

Shutdown audit at zzdds 0.3.11 (its default threaded runtime): `factory.zig` calls
`extensions.zzdds_destroy_factory`, which destroys `FactoryOwner` and its participant
stacks. `ParticipantStack.deinit` destroys its participant factory and discovery
before UDP transport teardown; UDP stops and joins receive threads and releases
port entries. Participant teardown stops/joins timers and receiving before native
entity cleanup when called outside callbacks, as this agent does. Thus factory
return is the host's threaded transport completion boundary. Provider generations
also have independent atomic reference counts and heap-owned allocation pools;
manager/prepared release cannot unload a generation still pinned by native users.
The process-long libc allocator remains valid for those final releases. This is not
a claim that logical entity retirement drains arbitrary shared-runtime callbacks;
enabling a future runtime path needs its own shutdown qualification.

The normal build/test graph contains no CounterStatus generator/provider/decoder.
`zig build fixtures` explicitly builds the CounterStatus DSO and `zz0_agent_compat`;
the latter retains reference/empty-XML compatibility and typed diagnostics without
DDS forwarding. The CounterStatus TOML files in `examples/counter` use the normal
executable and preserve existing firmware CREATE names. `test-fixtures` also tests
loaded-provider writes, live-graph shutdown, failed artifact/identity constraints,
late bind rollback and failed cleanup retry. `test-startup` exercises the actual
CLI, path bases and negative cases. CI keeps a Pico-free normal build/test job and
runs explicit fixtures/startup checks in Debug, ReleaseSafe and host LLVM TSan.
TSan DSOs stay uninstrumented, matching the released zzdds fixture policy.

The 62 core/fixture regressions pass in Debug, ReleaseSafe and host LLVM TSan;
real CLI checks pass in all three modes. The configured ReleaseSafe executable
delivers three CounterStatus samples to the separate DDS consumer and completes
RESET, client deletion and bounded checked shutdown. The independent eProsima
compatibility executable also passes. Previous hardware results belong to the
earlier built-in startup and are not new cutover evidence.

## Slice 4 automated checkpoint

`zig build test-multi-library` uses three separately generated DSOs from agent-owned
fixture IDL and the normal agent executable. It needs no Pico checkout. Projects A
and B select distinct types and an explicitly chosen equivalent Common::Reading;
their conflicting Common::Unused exports stay unselected. The third DSO supplies
a different Common::Reading. Inspection proves that load order does not select a
type, equivalent definitions have equal Minimal identifiers, a constrained different
selection fails, and duplicate/missing selections fail before readiness. An explicit
different selection without an identity constraint remains valid; no global
registration, automatic replacement or assignability policy is inferred.

Two clients reuse identical object IDs while a separate DDS consumer verifies
three selected types from both clients in three phases: initial publishing, RESET
of one client with the other preserved, and a changed-session reconnect of that
client. The test also checks malformed/trailing samples, private resource names,
same-session login/REUSE, client deletion and bounded shutdown with another graph
still live. All 18 distinct type/client/phase receipts are verified from decoded
DDS samples, separately from XRCE STATUS. Neither the agent nor consumer links the
fixture's generated sample types. A dedicated CI lane runs Debug, ReleaseSafe and
host LLVM TSan and saves inspection, agent and consumer logs.

Local Linux qualification passes in all three modes. Existing core/CounterStatus/
startup regressions also pass after sharing the provider-library build helper.
This is our DDS implementation in both processes, not independent-vendor evidence.
The explicit CounterStatus board commands and recovery checklist are in
[pico-acceptance.md](pico-acceptance.md). Matching demo documentation is prepared
in its clean worktree; the mixed firmware/MicroZig checkout is untouched.

Physical Pico forwarding/recovery against configured startup was reported passed
by the operator on 2026-11-11, using the previous firmware images without reflash.
The report covers the acceptance document's both-board receipt, agent restart,
each board reset independently and access-point recovery checks; raw logs and
artifact hashes were not supplied. See [the result](pico-acceptance.md#operator-reported-result-2026-11-11).
This completes the four implementation/acceptance slices locally. The older
hardware record remains historical; PR review and hosted CI are still ahead.
