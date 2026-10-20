# DDS-XRCE 1.0 audit: agent interoperability

The full change-by-change audit is maintained in the companion zz0_client
repository at `interop/spec-audit.md`. Sources are the
[OMG specification](https://www.omg.org/spec/DDS-XRCE/1.0/PDF),
[normative IDL](https://www.omg.org/spec/DDS-XRCE/20190301/dds_xrce_types.idl),
and resolved [DDSXRCE-4](https://issues.omg.org/issues/DDSXRCE-4).

The agent defaults to the published OMG login layout: 22-byte CREATE_CLIENT and
17-byte STATUS_AGENT without properties or header client key. The eProsima peer
test explicitly passes `--handshake=eprosima_v3` for its extra MTU/result fields.
These are compatibility fields, not changes mandated by the standard. The OMG
STATUS_AGENT prose and IDL disagree; we follow the IDL and resolved reduction,
and do not fabricate a success/error result field that is absent on the wire.

Plain application CDR without a DDS encapsulation header is supported by the
specification. The CounterStatus adapter/tests now select XCDR2 (§7.7.2).
CREATE replies preserve the request's object-ID bytes while the resource table
uses the ID derived from the prefix and ObjectKind (§7.7.6–7.7.9).

Empty publisher XML is a compatibility convention. Standard publisher XML must
contain a publisher element (§7.7.3.8.1); the demo's by-reference publisher is also
outside the specified binary/XML forms. Neither convention establishes standard
publisher configuration support.

Existing conformance gaps include repeat-login resource reset (§7.8.2.1), absent
stream ordering/duplicate suppression (§8.3.2.3), incomplete aligned/multiple
submessage handling (§8.3.3), reliable streams and deletion. WRITE_DATA's STATUS
requirement (§8.3.5.8) is not replaced by the eProsima test's behavior. An OK from
our agent remains local validation; it does not mean a DDS write occurred.

The CI suite tests a documented interoperability subset. It does not establish
any of the full conformance points defined in §2. On 2026-10-20 the operator
confirmed both reflashed boards passed simultaneous decoded publishing,
agent-restart recovery and WiFi reconnect recovery against the updated agent.
This supplies operator-reported hardware evidence for the new wire behavior.
Remote CI remains unrun.
