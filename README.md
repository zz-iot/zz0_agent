# Zenzen Zero Agent

Host-side DDS-XRCE agent for Zenzen Zero. It constructs client-owned DDS resources
from an explicit configuration and forwards provider-validated samples. The current
publishing subset supports bounded final types and modern XTypes 1.3 XCDR2.
See the [backend checkpoint](docs/real-dds-backend.md) for scope and qualification.

## Build and configure

Use Zig 0.17.0 and a sibling `zz0_client` checkout. Normal builds and core tests
need no Pico checkout or sample-type generation. The agent pins zzdds **0.3.11**,
which supplies zidl **0.3.27** for configuration generation, runtime code and the
loadable typesupport contract. CI pins client PR #2's merged commit,
`9ffef195bcac18d4695ef5f7a9c58a5bf9beab85`.

```sh
zig build
zig build test
./zig-out/bin/zz0_agent --help
```

Serving requires three explicit inputs:

- `--config FILE`: agent manifest with a resource filename, type bindings and
  the XRCE references that clients may request.
- The resource TOML file: zzdds participants, types, topics, endpoints, defaults
  and profiles. Its path resolves relative to the manifest.
- Repeatable `--library ALIAS=PATH`: generated typesupport libraries selected by
  manifest bindings. Library paths resolve relative to the invocation directory.

Repeatable `--sha256 ALIAS=64_HEX_DIGITS` constrains artifact hashes. Bindings may
also constrain a Minimal TypeIdentifier with `expected_identifier` (30 hex digits).
Both `--flag VALUE` and `--flag=VALUE` forms are accepted for valued options.
Unknown ordinary settings fail; `_setting` permits unknown optional settings and
reports them as skipped. Known invalid settings still fail. Catalog keys beginning
with `_` are literal reference names. See the [startup design](docs/configurable-startup-plan.md).

```sh
./zig-out/bin/zz0_agent --config app-agent.toml \
  --library project_a=providers/liba.so --library project_b=providers/libb.so \
  --check-config
```

`--check-config` parses both documents, resolves profiles, validates references and
checks binding/alias constraints without accessing library files. It explicitly
reports that provider ABI, export identity and capabilities remain unchecked.
`--inspect` additionally loads native provider code and checks the exact exports,
identities and wire capabilities; it reports hashes, generations, resolved settings
and profile origins without creating a DDS factory, entities or UDP listener.
Serving performs those checks before creating the factory and binding UDP last.
There is no built-in configuration or validation-only fallback. `--help` and
`--version` need no configuration. Hot reload is not implemented.

## CounterStatus example

With the sibling `zz0-pico-demo` IDL available, build the explicit fixtures:

```sh
zig build fixtures
./zig-out/bin/zz0_agent --config examples/counter/agent.toml \
  --library counter=zig-out/lib/libcounter_types.so --write-log=summary
```

Use the platform's actual shared-library filename (`.so` above is the Linux
example). `-Dcounter-idl=PATH` overrides the demo IDL; `-Dzidl=PATH` overrides its
bounded decoder generator. The provider/configuration generators use pinned zidl.
The [resource file](examples/counter/resources.toml) selects DDS domain 0, topic
`CounterStatusTopic`, XCDR2 and the existing Pico CREATE references. Firmware does
not need different CREATE names. Decode sample fields using the demo DDS consumer;
the production agent logs generic acceptance and bounded bytes.

`zig build fixtures` also installs `zz0_agent_compat`, an explicit legacy test
executable. It accepts publisher/writer references and the eProsima empty-XML
publisher convention, validates CounterStatus locally and never forwards to DDS.
The production executable rejects `--validate-only`. Arbitrary XML creation remains
unsupported.

## Sessions and observability

The UDP listener defaults to port 8888; `--port=N` overrides it and `--port=0`
selects an ephemeral port. Participant/topic CREATEs resolve exposed references;
publisher/writer CREATEs use binary definitions. STATUS reports construction and
backend write acceptance, including resource exhaustion and malformed samples.
Subscriber receipt is checked separately. UDP datagrams are bounded to 512 bytes,
including XRCE headers; fragmentation is outside the current subset.

Up to eight clients have independent resources, generations and write counters,
including when they reuse object IDs or session IDs. The peer plus session ID
routes messages without a client key. Repeating CREATE_CLIENT with the same key
and session preserves state and updates the peer address; changing the session
first cleans up that client's DDS graph. Cleanup failures retain the owner for
retry. RESET clears its graph; ProxyClient DELETE also frees its client slot.
Unknown sessions and malformed packets do not terminate service.

The normal executable expires clients after 600 seconds without a valid supported
request. `--client-idle-timeout-seconds=N` changes that interval; `0` disables it.
Valid requests refresh activity even when their STATUS reports an error; malformed
or unknown-session traffic does not. Expiry releases the client's DDS graph and
slot. Failed cleanup retains a blocked owner and retries at most once per second,
while other clients continue. Expiration and release are logged by client key.
Returning clients must log in and recreate their resources; the Pico application
already has timeout/recreation logic. Quiet applications should increase or disable
the timeout. On Linux host suspension does not count toward idle time.

The registry remains bounded and unauthenticated: a ninth key is rejected until a
slot is freed; active clients are never evicted to admit it. Use distinct client
keys, such as the current Pico firmware's MAC-derived identities. This is a local
retention policy, not negotiated liveliness or reliable-stream support. Reusable
session/server APIs and the compatibility executable default to expiry disabled;
direct session users call `maintain()` with awake-clock timestamps before dispatch.
See the [cleanup design](docs/inactive-client-cleanup-plan.md) for failure and
reconnection rules.

- `--write-log=none|summary|hex` selects generic per-client write output.
- `--stats-every=N` prints acceptance counters every N writes; zero disables it.
- `--hex-bytes=N` bounds hex output.
- `--max-datagrams=N` exits after N datagrams and performs checked cleanup.
- `--handshake=omg_1_0|eprosima_v3` selects the explicit login layout.

Normal OS signal handling is unchanged; bounded normal exit exercises checked
cleanup, while this work does not add a graceful SIGTERM protocol.

## Tests

`zig build test` covers sample-independent protocol, UDP, configuration and CLI
behavior. `zig build test-fixtures` covers CounterStatus, real DDS, loaded-provider
ownership and compatibility regressions. `zig build test-startup` checks the real
CLI's offline/inspection paths, constraints and failed-bind rollback using the
generated provider. CI runs these in Debug, ReleaseSafe and host LLVM TSan; DSOs
remain uninstrumented because Zig embeds an incompatible second sanitizer runtime
in instrumented DSOs. The core CI job has no Pico checkout.

`zig build test-multi-library` independently generates project libraries and drives
one configured agent with two XRCE clients. A separate DDS process checks three
types from both clients across RESET/reconnect and idle expiry/recreation (24
distinct receipts), alongside equivalent/conflicting
exports, unused exports and malformed samples. It needs no Pico checkout and runs
in its own CI lane in Debug, ReleaseSafe and host TSan. See
[the qualification details](interop/README.md#multiple-project-libraries) and
[configured Pico hardware commands and reported results](docs/pico-acceptance.md).

## Roadmap

The [client-owned backend adapter](docs/backend-adapter.md) and configured startup
are merged and qualified with managed UDP ownership and DDS forwarding.
See the [real backend checkpoint](docs/real-dds-backend.md).

See the [DDS backend implementation plan](docs/dds-backend-plan.md) for the
implementation checkpoints and the boundary between shared zzdds construction and
client-owned XRCE resources.

See [ROADMAP.md](ROADMAP.md) for current scope, interoperability goals and the
planned path toward DDS bridging, reliable sessions and subscriptions.

## Independent interoperability

See [interop/README.md](interop/README.md) for the pinned eProsima peer test,
local commands, CI workflow and exact scope of the verified subset.

The default login encoding follows the published OMG 1.0 IDL. Use
`--handshake=eprosima_v3` only for the pinned eProsima peer's extra login fields.
See [the spec audit](interop/spec-audit.md) for normative fixes and compatibility
differences; the implementation does not yet satisfy an OMG conformance profile.

## XCDR2 encoding revision

This project explicitly uses modern **XTypes 1.3 XCDR2**. This agrees with zidl
and zzdds; it does not select the older XTypes 1.2 delimiter format referenced
by XRCE 1.0. The constrained `zidl --profile xrce` limits type features and does
not force XCDR1 or select historical XCDR2. Future historical-peer compatibility
must be explicit; future XTypes 1.4 support will follow formal publication/review.
