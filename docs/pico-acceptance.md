# Configured agent: Pico forwarding and recovery

This checks the configured startup path against the existing Pico WH and Pico 2 WH
firmware CREATE sequence. The operator reported this acceptance pass successful on
2026-11-11 using the previously tested firmware images, without reflashing. The
automated multi-library checks and separate-process CounterStatus smoke also pass
locally. The earlier built-in-startup hardware record remains separate.

## Build the host programs

Use Zig 0.17.0. From `zz-dev`:

```sh
cd zz0_agent
zig build fixtures -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
cd ../zz0-pico-demo/dds-consumer
zig build -Doptimize=ReleaseSafe
cd ../..
```

The explicit fixture build generates `libcounter_types.so` from the sibling Pico
IDL with pinned zidl 0.3.27. The agent and consumer use zzdds 0.3.11. Normal agent
builds need no Pico checkout; this particular example needs its IDL. These commands
use Linux's library filename.

The current firmware's participant/topic references and binary publisher/writer
CREATE records are unchanged. Boards already running that firmware do not need to
be reflashed merely for this startup change.

## Check the configuration

From `zz-dev`:

```sh
./zz0_agent/zig-out/bin/zz0_agent \
  --config zz0_agent/examples/counter/agent.toml \
  --library counter=zz0_agent/zig-out/lib/libcounter_types.so --check-config
./zz0_agent/zig-out/bin/zz0_agent \
  --config zz0_agent/examples/counter/agent.toml \
  --library counter=zz0_agent/zig-out/lib/libcounter_types.so --inspect
```

The offline check must explicitly say ABI/identity/capabilities are unchecked.
Inspection must report `main/CounterStatus`, provider `counter`, wire validation,
a Minimal TypeIdentifier and the artifact hash, then exit without a UDP listener.
The resource file resolves relative to the manifest; the library path resolves
relative to the invocation directory.

## Start the agent and consumers

Start the agent in one terminal, then one consumer per board in two other
terminals. All commands below run from `zz-dev`:

```sh
./zz0_agent/zig-out/bin/zz0_agent \
  --config zz0_agent/examples/counter/agent.toml \
  --library counter=zz0_agent/zig-out/lib/libcounter_types.so \
  --write-log=summary
```

```sh
./zz0-pico-demo/dds-consumer/zig-out/bin/counter-consumer \
  --board=pico-wh --count=10 --timeout=30
```

```sh
./zz0-pico-demo/dds-consumer/zig-out/bin/counter-consumer \
  --board=pico2-wh --count=10 --timeout=30
```

The agent must report configured DDS forwarding and a listener on port 8888 before
enabling the boards. Each consumer must print its board's decoded samples and
`received 10 samples`, then exit successfully. Restart consumers if they time out
before the boards connect. Agent acceptance logs alone do not prove DDS receipt;
the agent now logs generic write information rather than decoded CounterStatus.

The example uses domain 0, `CounterStatusTopic`, XCDR2, KEEP_LAST depth 1 and finite
256-instance limits. Keep trials short and restart the agent between scenarios;
a long soak needs different instance-lifecycle/configuration work.

## Recovery trials

For each trial, restart both consumers before checking receipt. Record successful
exit and the observed counters for each board:

| Trial | Expected observation |
| --- | --- |
| Both boards active | Both consumers receive 10 correctly decoded samples. |
| Stop/restart agent, keep boards powered | Both boards reconnect; consumers receive again with higher counters. Restart the agent using the same explicit config/library command. |
| Reset Pico WH, keep Pico 2 WH and agent running | WH counters restart low; Pico 2 WH counters remain high; both consumers succeed. |
| Reset Pico 2 WH, keep Pico WH and agent running | Pico 2 WH counters restart low; WH counters remain high; both consumers succeed. |
| Disable/restore access point, keep boards powered | Both boards reconnect and both consumers receive again. |

Normal OS signal termination is unchanged. Stopping/restarting a process exercises
client recovery; it does not demonstrate graceful SIGTERM cleanup. Automated tests
separately verify checked cleanup on bounded normal exit, including live graphs.

Record the agent commit, library hash from inspection, firmware revision and
trial outcomes when repeating the test.

## Operator-reported result (2026-11-11)

The operator reported that the hardware tests with the previous Pico/Pico2 firmware
images checked out according to this acceptance document. This records successful
consumer receipt for both boards and the documented recovery checks:

| Trial | Reported result |
| --- | --- |
| Both boards publishing to their filtered DDS consumers | Passed the documented 10-sample checks. |
| Agent stop/restart with boards powered | Passed. |
| Pico WH reset while Pico 2 WH and agent remain running | Passed. |
| Pico 2 WH reset while Pico WH and agent remain running | Passed. |
| Access-point loss and restoration | Passed. |

This is operator-reported evidence for configured startup with unchanged firmware;
no raw logs, per-trial counter values or artifact hashes accompanied the report.
It completes the planned physical-board acceptance for this change. Longer soak,
independent-vendor DDS and graceful signal shutdown remain outside this pass.
