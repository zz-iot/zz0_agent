# Zenzen Zero Agent

Host-side DDS-XRCE agent for Zenzen Zero.

The UDP server supports up to eight demo clients. `CREATE_CLIENT` establishes a
client key, peer address and session ID; subsequent datagrams are routed to that
client. Normal operation constructs real DDS resources and forwards checked
CounterStatus samples using the built-in configuration. See the
[real backend checkpoint](docs/real-dds-backend.md) for its exact scope.

Participant/topic CREATEs resolve configured references; publisher/writer CREATEs
use binary definitions. The shared resource builder creates actual DDS objects
with independent ownership per client. STATUS replies report construction and
write results, including unknown references, mismatches and resource exhaustion.
A successful write means DDS backend acceptance; subscriber receipt is checked
separately. Generated CounterStatus validation rejects malformed samples with
ERR_INVALID_DATA and supplies optional decoded telemetry.

`--validate-only` selects the older compatibility test fixture. It accepts
publisher/writer references and the eProsima empty-XML publisher convention,
records resources and validates samples locally, and never forwards into DDS.
Arbitrary XML entity creation remains unsupported. Use this mode only for
compatibility tests, not the current Pico firmware.

Runtime observability is optional:

- `--write-log=none` disables per-sample output
- `--write-log=summary` prints client key, object id, payload length, and per-client write count
- For the Pico demo datawriter, `--write-log=summary` prints decoded
  `CounterStatus` fields.
- `--write-log=hex` prints a bounded hex dump of each payload
- `--stats-every=N` prints per-client counters every `N` accepted writes
- `--hex-bytes=N` limits the hex dump size for `--write-log=hex`

## Build and run

Use Zig 0.17.0. The current development layout expects sibling checkouts of
`zz0_client` and `zz0-pico-demo`. DDS construction and provider support come from
pinned zzdds **0.3.11**, which supplies zidl **0.3.27** for both generation and
runtime code. A sibling zzdds checkout is no longer required.
Hosted CI pins the companion client's merged binary CREATE and lifecycle support
at commit `9ffef195bcac18d4695ef5f7a9c58a5bf9beab85` (zz0_client PR #2).

```sh
zig build
zig build test
./zig-out/bin/zz0_agent --write-log=summary
```

The UDP listener uses port 8888 (`--port=N` overrides it; `--port=0` selects an
ephemeral test port). Override the generator with
`-Dzidl=/path/to/zidl` and the demo IDL with `-Dcounter-idl=/path/to/counter_types.idl`.
The default uses the bounded CounterStatus DDS configuration: domain 0, topic
`CounterStatusTopic`, XCDR2 endpoints and standard binary publisher/writer CREATEs.
The Pico firmware uses this path. General provider/catalog configuration is still
planned; this executable does not yet load arbitrary typesupport libraries.

## Demo client isolation

Each client has its own resources and decode/write counters. Different clients
may use the same object IDs and session ID. The UDP peer plus session ID routes
messages that omit the client key. Repeating CREATE_CLIENT with the same key and
session ID preserves resources/counters and updates the peer address. A changed
session ID first cleans up that client's DDS resources. Cleanup failure retains
the client for a retry and blocks further construction/writes. RESET clears its
resources; deleting the ProxyClient also frees its client slot. In
`--validate-only`, each valid CREATE_CLIENT resets the local fixture's state.
Conflicting keys on the same peer/session are rejected. Unknown sessions and
malformed datagrams do not terminate the server.

This is a bounded, unauthenticated demo registry, not a complete XRCE session
implementation: keys identify clients rather than authenticate them, slots have
no idle expiry, and a ninth distinct key is rejected until a client slot is freed.
Using the same key on two active boards prevents independent ownership. Use the MAC-derived identities in the current Pico firmware.

`zig build test` includes the protocol tests, UDP exchanges, overlapping-object
isolation, reconnect behavior, malformed-packet handling, and client limits.

## Roadmap

An initial [client-owned backend adapter](docs/backend-adapter.md) is implemented
and tested with managed UDP ownership and default DDS forwarding.
See the [real backend checkpoint](docs/real-dds-backend.md).

See the [DDS backend implementation plan](docs/dds-backend-plan.md) for the
next integration steps and the boundary between shared zzdds construction and
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
