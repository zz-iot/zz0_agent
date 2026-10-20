# Roadmap

The agent currently implements a small DDS-XRCE subset for the Pico demo.
This roadmap describes intended development order, not release commitments or
an assertion of XRCE conformance.

## Current state

- UDP session registration for up to eight clients, with independent resources
  and statistics.
- Entity creation by reference against a configured catalog.
- WRITE_DATA validation, STATUS replies and generated CounterStatus decoding.
- Tests for malformed packets, client isolation, registration/rebinding,
  resource validation and capacity limits.
- Hardware validation with Pico WH and Pico 2 WH, including simultaneous
  publishing, agent restarts and WiFi disconnect/reconnect recovery.

The agent does not yet create DDS entities or forward samples to zzdds.
An OK write status currently means local acceptance, not DDS delivery.
The client registry has no idle expiry or authentication. This is a demo
implementation, not a general-purpose or fully conformant XRCE agent.

## 1. Establish interoperability and scope

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

Broader entity representations, fragmentation, additional transports and richer
QoS support can expand the supported profile. Runtime type registration,
DynamicData and broader XTypes integration would support arbitrary-type agents;
these should follow concrete requirements rather than block the known-type path.

## References

- [OMG DDS-XRCE 1.0](https://www.omg.org/spec/DDS-XRCE/1.0)
- Companion roadmap: `ROADMAP.md` in the `zz0_client` repository
- [eProsima Micro XRCE-DDS](https://github.com/eProsima/Micro-XRCE-DDS)
