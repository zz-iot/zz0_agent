# Zenzen Zero Agent

Host-side DDS-XRCE agent for Zenzen Zero.

The initial implementation handles the first XRCE session smoke test over UDP:
`CREATE_CLIENT` request bytes in, `STATUS_AGENT` response bytes out. DDS bridging
comes after this protocol slice is stable.

It also decodes by-reference `CREATE` requests, validates the requested reference
against a configured catalog, records accepted resources in an in-memory table,
and returns XRCE `STATUS` results for OK, matched, mismatch, unknown reference,
and resource exhaustion cases. Actual DDS resource creation still needs to be
wired to `zzdds`.

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
- `--write-log=summary` prints object id, payload length, and total write count
- For the Pico demo datawriter, `--write-log=summary` prints decoded
  `CounterStatus` fields.
- `--write-log=hex` prints a bounded hex dump of each payload
- `--stats-every=N` prints aggregate counters every `N` accepted writes
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

The UDP listener uses port 8888. Override the generator with
`-Dzidl=/path/to/zidl` and the demo IDL with `-Dcounter-idl=/path/to/counter_types.idl`.
The agent currently validates and logs XRCE samples; DDS forwarding is pending.
