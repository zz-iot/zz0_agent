# Roadmap

The agent currently implements a small DDS-XRCE subset for the Pico demo.
This roadmap describes intended development order, not release commitments or
an assertion of XRCE conformance.

The implemented publishing path is documented in the
[DDS backend plan](docs/dds-backend-plan.md). Shared resource construction,
authoring and multi-provider bindings are now available in zzdds (through PR
#113). The agent now pins zzdds 0.3.11 for incremental construction, explicit
endpoint wire representation and handle retirement. Client cleanup is part of
the real backend.

## Completed: configurable startup

The [startup design](docs/configurable-startup-plan.md) is implemented and merged in
[agent PR #3](https://github.com/zz-iot/zz0_agent/pull/3), with the companion
instructions and hardware record merged in
[demo PR #3](https://github.com/zz-iot/zz0-pico-demo/pull/3) on 2026-11-11.

The normal executable loads explicitly selected typesupport libraries, resolves
shared resource/profile TOML and exposes configured XRCE references. Core builds
and tests need no Pico checkout. CounterStatus and legacy compatibility are explicit
fixtures. All three hosted CI jobs passed, including multi-project DDS receipt
across RESET/reconnect. The operator also reports configured Pico acceptance with
unchanged firmware; see [the recorded result](docs/pico-acceptance.md#operator-reported-result-2026-11-11).
The four planned implementation/acceptance slices are complete.

DDS interoperability with other vendors is covered by zzdds's separate interop
work. Agent qualification focuses on XRCE behavior, resource/provider mapping and
receipt through zzdds consumers. Hot reload remains later, application-driven work.

## Current state

- UDP session registration for up to eight clients, with independent resources
  and statistics.
- Participant/topic references and binary publisher/writer creation against a configured catalog.
- Provider-backed WRITE_DATA validation and STATUS replies; CounterStatus decoding
  remains in explicit fixtures and the DDS consumer.
- Tests for malformed packets, client isolation, registration/rebinding,
  resource validation and capacity limits.
- Operator-reported DDS consumer receipt for Pico WH and Pico 2 WH together,
  including recovery after agent restart, Pico WH reset with Pico 2 WH left
  running, and access-point loss/restoration (2026-11-04). Each board-filtered
  consumer received 10 samples per scenario; see the backend evidence record.

Normal operation now creates DDS entities and forwards checked samples;
[scope and local evidence](docs/real-dds-backend.md). Its OK status means DDS
backend acceptance, not subscriber receipt. The explicit `zz0_agent_compat`
executable reports local acceptance without DDS forwarding.
The client registry has configurable idle expiry but no authentication. This is a demo
implementation, not a general-purpose or fully conformant XRCE agent.

## 1. Establish interoperability and scope

The pinned eProsima client test now covers the limited request/sample subset
documented in `interop/README.md`, with successful hosted CI execution in
[the PR #3 qualification run](https://github.com/zz-iot/zz0_agent/actions/runs/43059511466).
The normative review and remaining compliance
gaps are recorded in `interop/spec-audit.md`; eProsima-specific login encoding
is opt-in. Remaining:

- Maintain a support matrix against the OMG DDS-XRCE specification, documenting
  supported messages, representations, session/stream behavior and limits.
- Add independently sourced wire fixtures and negative cases; shared code with
  zz0_client must not be the only protocol oracle.
- Define explicit behavior for unsupported requests and multi-submessage packets.

Exit criterion: a documented subset works with an independent implementation,
with automated regressions for discrepancies found.

## 2. Bridge configured types into zzdds — completed

The [initial backend adapter](docs/backend-adapter.md) now provides normalized
request handling, per-client associations and retryable cleanup with fake-backend
tests. Managed UDP ownership and configured real DDS forwarding are merged;
see the [real backend checkpoint](docs/real-dds-backend.md). Completed:

- Separated XRCE request handling from DDS backend operations and demo telemetry.
- Mapped configured references to actual zzdds participants, topics, publishers
  and datawriters, using zidl-generated typesupport for known types.
- Forwarded CounterStatus writes and mapped backend failures to appropriate statuses.
- Defined precisely what a successful write response guarantees.

Acceptance: samples from both Pico boards reach separate DDS consumer processes
through zzdds, with client resources kept separate. This is covered by automated
checks and the operator-reported hardware pass. DDS vendor qualification is owned
by the separate zzdds interop effort.

General XTypes DynamicData is not a prerequisite for this milestone. A configured
catalog of generated types is sufficient for a deliberately limited bridge.

## 3. Complete lifecycle and strengthen delivery behavior

Entity/ProxyClient deletion, RESET, checked cleanup, repeat-login behavior, peer
rebinding and restart recovery are implemented and covered. Remaining:

- Inactive-client reclamation is implemented with retryable cleanup and
  automated expiry/reconnection checks. The operator also confirmed default-timeout
  expiry and resumed consumer receipt on hardware; see the
  [cleanup design](docs/inactive-client-cleanup-plan.md).
- Test packet loss, duplication, reordering, delayed replies and sequence wrap.
- Implement reliable stream behavior, acknowledgement/retransmission and
  duplicate suppression for the supported profile, coordinated with zz0_client.
- Add fuzzing and sustained-load/resource-usage checks.

Application retries alone must not be presented as XRCE reliable-stream support.

## 4. Support DDS-to-client data

- Add datareaders, read requests and delivery to clients.
- Define bounded queues, backpressure, cancellation and cleanup behavior.
- Validate a complete bidirectional embedded application.

## Later, driven by applications

Loadable generated typesupport libraries and a checked multi-provider binding
contract now exist in zidl/zzdds. The backend plan reuses them so the agent can
support configured application types without rebuilding. It does not add another
library format or require general DynamicData. Live provider replacement and
resource graph reload remain later work.

Broader entity representations, fragmentation, additional transports and richer
QoS support can expand the supported profile. Runtime type registration,
DynamicData and broader XTypes integration would support arbitrary-type agents;
these should follow concrete requirements rather than block the known-type path.

## References

- [OMG DDS-XRCE 1.0](https://www.omg.org/spec/DDS-XRCE/1.0)
- Companion roadmap: `ROADMAP.md` in the `zz0_client` repository
- [eProsima Micro XRCE-DDS](https://github.com/eProsima/Micro-XRCE-DDS)
