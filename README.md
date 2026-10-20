# Zenzen Zero Agent

Host-side DDS-XRCE agent for Zenzen Zero.

The UDP server supports up to eight demo clients. `CREATE_CLIENT` establishes a
client key, peer address and session ID; subsequent datagrams are routed to that
client. DDS bridging remains a separate development step.

It also decodes by-reference `CREATE` requests, validates the requested reference
against a configured catalog, records accepted resources in a per-client in-memory table,
and returns XRCE `STATUS` results for OK, matched, mismatch, unknown reference,
and resource exhaustion cases. Actual DDS resource creation still needs to be
wired to `zzdds`.

The eProsima empty-XML publisher convention is also accepted for the demo participant;
arbitrary XML entity creation remains unsupported.

The current payload slice also accepts XRCE `WRITE_DATA` requests for created
XRCE datawriters, updates in-memory counters, and returns `STATUS` replies for
success, unknown object ids, and object-kind mismatches.

For the current Pico demo datawriter, the agent also validates the payload by
decoding it as the generated `CounterStatus` type from
`zz0-pico-demo/idl/counter_types.idl`. Valid demo samples update typed decode
telemetry; malformed demo samples are rejected with `ERR_INVALID_DATA`. This is
a demo validation step, not the final generic XRCE-to-DDS forwarding model.

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
`zz0_client` and `zz0-pico-demo`. The build fetches the pinned zidl 0.3.21
release and builds its host generator automatically; the payload decoder uses
the runtime from the same package.

```sh
zig build
zig build test
./zig-out/bin/zz0_agent --write-log=summary
```

The UDP listener uses port 8888 (`--port=N` overrides it; `--port=0` selects an
ephemeral test port). Override the generator with
`-Dzidl=/path/to/zidl` and the demo IDL with `-Dcounter-idl=/path/to/counter_types.idl`.
The agent currently validates and logs XRCE samples; DDS forwarding is pending.

## Demo client isolation

Each client has its own resources and decode/write counters. Different clients
may use the same object IDs and session ID. The UDP peer plus session ID routes
messages that omit the client key. A valid CREATE_CLIENT starts a fresh session
for that key, clearing only that client's resources/counters and updating its
peer address; a reboot or port change therefore reuses its existing slot.
Conflicting keys on the same peer/session are rejected. Unknown sessions and
malformed datagrams do not terminate the server.

This is a bounded, unauthenticated demo registry, not a complete XRCE session
implementation: keys identify clients rather than authenticate them, slots have
no idle expiry, and a ninth distinct key is rejected until the agent restarts.
Using the same key on two active boards causes them to replace each other's
session. Use the MAC-derived identities in the current Pico firmware.

`zig build test` includes the protocol tests, UDP exchanges, overlapping-object
isolation, reconnect behavior, malformed-packet handling, and client limits.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for current scope, interoperability goals and the
planned path toward DDS bridging, reliable sessions and subscriptions.

## Independent interoperability

See [interop/README.md](interop/README.md) for the pinned eProsima peer test,
local commands, CI workflow and exact scope of the verified subset.

The default login encoding follows the published OMG 1.0 IDL. Use
`--handshake=eprosima_v3` only for the pinned eProsima peer's extra login fields.
See [the spec audit](interop/spec-audit.md) for normative fixes and compatibility
differences; the implementation does not yet satisfy an OMG conformance profile.
