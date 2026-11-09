# Roadmap

The agent currently implements a small DDS-XRCE subset for the Pico demo.
This roadmap describes intended development order, not release commitments or
an assertion of XRCE conformance.

The next implementation is scoped in the
[DDS backend plan](docs/dds-backend-plan.md). Shared resource construction,
authoring and multi-provider bindings are now available in zzdds (through PR
#113). The agent now pins zzdds 0.3.11 for incremental construction, explicit
endpoint wire representation and handle retirement. Client cleanup is part of
the real backend.

## Current state

- UDP session registration for up to eight clients, with independent resources
  and statistics.
- Participant/topic references and binary publisher/writer creation against a configured catalog.
- WRITE_DATA validation, STATUS replies and generated CounterStatus decoding.
- Tests for malformed packets, client isolation, registration/rebinding,
  resource validation and capacity limits.
- Operator-reported DDS consumer receipt for Pico WH and Pico 2 WH together,
  including recovery after agent restart, Pico WH reset with Pico 2 WH left
  running, and access-point loss/restoration (2026-11-04). Each board-filtered
  consumer received 10 samples per scenario; see the backend evidence record.

Normal operation now creates DDS entities and forwards checked samples;
[scope and local evidence](docs/real-dds-backend.md). Its OK status means DDS
backend acceptance, not subscriber receipt. The explicit `--validate-only` compatibility fixture
reports local acceptance without DDS forwarding.
The client registry has no idle expiry or authentication. This is a demo
implementation, not a general-purpose or fully conformant XRCE agent.

## 1. Establish interoperability and scope

The pinned eProsima client test now covers the limited request/sample subset
documented in `interop/README.md`. CI configuration is included; remote CI
execution is not yet evidence. The normative review and remaining compliance
gaps are recorded in `interop/spec-audit.md`; eProsima-specific login encoding
is opt-in. Remaining:

- Maintain a support matrix against the OMG DDS-XRCE specification, documenting
  supported messages, representations, session/stream behavior and limits.
- Exercise an independent XRCE client against this agent, starting with
  CREATE_CLIENT, by-reference CREATE and WRITE_DATA.
- Add independently sourced wire fixtures and negative cases; shared code with
  zz0_client must not be the only protocol oracle.
- Define explicit behavior for unsupported requests and multi-submessage packets.

Exit criterion: a documented subset works with an independent implementation,
with automated regressions for discrepancies found.

## 2. Bridge a known type into zzdds

The [initial backend adapter](docs/backend-adapter.md) now provides normalized
request handling, per-client associations and retryable cleanup with fake-backend
tests. Managed UDP ownership and real DDS forwarding are implemented locally;
see the [real backend checkpoint](docs/real-dds-backend.md). The existing demo path is
unchanged.

- Separate XRCE request handling from DDS backend operations and demo telemetry.
- Map configured references to actual zzdds participants, topics, publishers
  and datawriters, using zidl-generated typesupport for known types.
- Forward CounterStatus writes and map backend failures to appropriate statuses.
- Define precisely what a successful write response guarantees.

Exit criterion: samples from both Pico boards reach an independent DDS
subscriber through zzdds, with client resources kept separate.

General XTypes DynamicData is not a prerequisite for this milestone. A configured
catalog of generated types is sufficient for a deliberately limited bridge.

## 3. Complete lifecycle and strengthen delivery behavior

- Add entity/session deletion, resource cleanup and bounded client reclamation.
- Specify duplicate registration, endpoint rebinding and restart behavior.
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
