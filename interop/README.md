# Independent XRCE interoperability

This host-only test drives `zz0_agent` with eProsima Micro XRCE-DDS Client v3.0.1.
All request framing and sample CDR come from the upstream C SDK and Micro-CDR.

It checks session login; by-reference participant, topic and writer creation;
empty-XML publisher creation; unknown-reference rejection; and plain CDR
CounterStatus acceptance. Both the client status and the agent's decoded fields
`{counter=42, board="eprosima", payload length=3}` are asserted. A truncated
sample must return ERR_INVALID_DATA without a second successful write.

With sibling `zz0_client` and `zz0-pico-demo` checkouts, Zig 0.17.0, CMake and
a C compiler, run from this repository on Linux:

```sh
python3 interop/build_peers.py --work /tmp/zz0-agent-peers
zig build -Doptimize=ReleaseSafe
python3 interop/run.py --agent zig-out/bin/zz0_agent \
  --prefix /tmp/zz0-agent-peers/install --logs /tmp/zz0-agent-interop
```

The exact upstream client and Micro-CDR revisions are pinned in `build_peers.py`.
They are built without source patches and outside the repo. CI caches the build
by script hash, runs Debug/ReleaseSafe unit tests and this live test, and uploads
logs even after failure. The agent uses an ephemeral UDP port, leaving the Pico
agent on port 8888 alone. Tests require real localhost UDP sockets. All child
processes have deadlines and are stopped on success or failure.

CI pins the companion zz0_client checkout to commit
`90f56a2f1f62263ae85731f485cf9cd4cc0ca448` (interoperability corrections).
Manual dispatch accepts `client_ref` to test another branch, tag or commit;
leaving it empty uses the pin. The demo checkout supplies only the existing
CounterStatus IDL to the agent build; firmware is not needed for the interop test.

This tests local acceptance, not DDS delivery: zz0_agent has no DDS bridge yet.
The runner explicitly selects `--handshake=eprosima_v3`. The test uses individual
requests over a best-effort stream, no properties,
keyless session headers, little-endian CDR and bounded, unfragmented packets.
It does not establish reliable-stream, multi-operation-datagram, deletion,
subscription, authentication or general XRCE conformance. The eProsima empty-XML convention
is the only XML creation form accepted; arbitrary XML profiles are unsupported.
Both empty XML and the existing by-reference publisher are demo compatibility
forms, not standard publisher XML/binary support.

## Wire correction affecting the Pico demo

XRCE sample bytes now use plain CDR, without a DDS encapsulation header. The
companion Pico serializer was updated together with this agent; rebuild/reflash
it when switching to this agent. Legacy encapsulated samples are not guessed
from their first bytes, which could equally be a valid counter value. On
2026-10-20 the operator confirmed both reflashed boards passed simultaneous
decoded publishing, agent-restart recovery and WiFi reconnect recovery against
the updated agent.

## Normative audit

See [spec-audit.md](spec-audit.md). Normal operation defaults to
`--handshake=omg_1_0`; only the explicitly selected eProsima mode adds MTU/result
fields. The published OMG STATUS_AGENT IDL has no result field.
