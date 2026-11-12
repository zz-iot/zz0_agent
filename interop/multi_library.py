#!/usr/bin/env python3
"""Qualify explicit project libraries through the normal agent and a separate DDS process."""
import argparse
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import time
from dds_smoke import create_binary, create_reference, string
from process import Process

OK, MATCHED, UNKNOWN, INVALID = 0, 1, 0x84, 0x85
TOPICS = ("MultiTemperature", "MultiPressure", "MultiReading")
REFERENCES = ("Multi::TemperatureTopic", "Multi::PressureTopic", "Multi::ReadingTopic")


def graph(client, expected=OK):
    operations = [(client, 1, create_reference(1, 0x1100, 1, "Multi::Participant", 204), expected)]
    for i, reference in enumerate(REFERENCES):
        operations.append((client, 1, create_reference(2 + i, 0x1200 + i * 0x1000, 2, reference, 0x1100), expected))
    operations.append((client, 1, create_binary(5, 0x1300, 3, b"\x01\0\0\0" + string("pub") + b"\0", 0x1100), expected))
    for i, topic in enumerate(TOPICS):
        operations.append((client, 1, create_binary(6 + i, 0x1500 + i * 0x1000, 5, string(topic) + b"\0", 0x1300), expected))
    return operations


def login(client, session=0x81):
    return (client, 0, b"XRCE\x01\x00ZZ" + bytes((1, 2, 3, client + 1, session, 0)), OK)


def sample(client, phase, kind):
    identifier = phase * 1000 + (client + 1) * 100 + kind + 1
    if kind == 0:
        return struct.pack("<Id", identifier, 12.5 + phase + client * 10)
    if kind == 1:
        return struct.pack("<Ii", identifier, 1000 + phase + client * 100) + string("project-b")
    return struct.pack("<Ii", identifier, -10 - phase - client)


def write(client, phase, kind, data=None, expected=OK):
    if data is None:
        data = sample(client, phase, kind)
    return (client, 7, struct.pack("<HH", 50 + phase, 0x1500 + kind * 0x1000) + data, expected)


class Client:
    def __init__(self, port):
        self.port = port
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.settimeout(5)
        self.sequence = 0
        self.session = 0x81
        self.sent = 0

    def exchange(self, kind, payload, expected):
        session, stream = (0x80, 0) if kind == 0 else (self.session, 1)
        sequence = self.sequence
        flags = 3 if kind == 1 else 1
        self.sequence += 1
        self.sent += 1
        self.socket.sendto(struct.pack("<BBHBBH", session, stream, sequence, kind, flags, len(payload)) + payload, ("127.0.0.1", self.port))
        if kind == 12:  # RESET deliberately has no response.
            return
        reply, _ = self.socket.recvfrom(512)
        if struct.unpack_from("<H", reply, 2)[0] != sequence:
            raise AssertionError("uncorrelated sequence")
        if kind == 0:
            if len(reply) != 17 or reply[4] != 4 or reply[8:12] != b"XRCE":
                raise AssertionError(f"invalid login: {reply.hex()}")
            self.session = payload[12]
        elif len(reply) != 14 or reply[4] != 5 or reply[8:12] != payload[:4] or reply[12] != expected:
            raise AssertionError(f"request {kind}: expected status={expected:02x}, got {reply.hex()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, type=Path)
    parser.add_argument("--consumer", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--project-a", required=True, type=Path)
    parser.add_argument("--project-b", required=True, type=Path)
    parser.add_argument("--conflict", required=True, type=Path)
    parser.add_argument("--logs", required=True, type=Path)
    args = parser.parse_args()
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    libraries = ["--library", f"project_a={args.project_a.resolve()}", "--library", f"project_b={args.project_b.resolve()}", "--library", f"conflict={args.conflict.resolve()}"]
    template = args.config.read_text()
    original_binding = 'type_name = "Common::Reading"\nprovider = "project_b"'
    with tempfile.TemporaryDirectory(prefix="zz0-projects-") as directory:
        config = Path(directory) / "agent.toml"
        (config.parent / "resources.toml").write_text((args.config.parent / "resources.toml").read_text())
        config.write_text(template)
        base = ["--config", str(config), *libraries]

        def inspect(name, expected=0, extra=(), reverse=False):
            flags = ["--config", str(config), *([*libraries[4:6], *libraries[2:4], *libraries[0:2]] if reverse else libraries), "--inspect", *extra]
            result = subprocess.run([str(args.agent.resolve()), *flags], capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            (logs / f"{name}.log").write_text(output)
            if result.returncode != expected or "listening for DDS-XRCE UDP" in output or "ThreadSanitizer" in output:
                raise AssertionError(f"inspection {name} failed: {output}")
            if expected == 0:
                for kind in ("writer", "reader"):
                    if f"{kind} main/temperature: representation=XCDR2" not in output or f"origin {kind} main/temperature data_representation: profile=Wire" not in output:
                        raise AssertionError(f"missing {kind} settings/origin: {output}")
            return output

        def identity(output, provider):
            match = re.search(r"type main/Common::Reading provider=" + provider + r" .*minimal=([0-9a-f]{30})", output)
            if not match:
                raise AssertionError(f"missing selected export {provider}: {output}")
            if "type main/Common::Unused" in output:
                raise AssertionError("unselected conflicting export was registered")
            return match.group(1)

        identifier = identity(inspect("selected-b"), "project_b")
        if identity(inspect("reversed-load-order", reverse=True), "project_b") != identifier:
            raise AssertionError("load order changed the selected identity")
        config.write_text(template.replace(original_binding, 'type_name = "Common::Reading"\nprovider = "project_a"'))
        if identity(inspect("equivalent-a"), "project_a") != identifier:
            raise AssertionError("equivalent generated exports have different identifiers")
        config.write_text(template.replace(original_binding, 'type_name = "Common::Reading"\nprovider = "conflict"'))
        if identity(inspect("explicit-different-type"), "conflict") == identifier:
            raise AssertionError("different generated definitions have equal identifiers")
        constrained = original_binding + f'\nexpected_identifier = "{identifier}"'
        config.write_text(template.replace(original_binding, constrained.replace('provider = "project_b"', 'provider = "conflict"')))
        if "TypeIdentityMismatch" not in inspect("conflicting-selection", 1):
            raise AssertionError("conflicting constrained selection was accepted")
        config.write_text(template.replace('type_name = "ProjectB::Pressure"\nprovider = "project_b"', 'type_name = "ProjectB::Pressure"\nprovider = "project_a"'))
        if "UnknownType" not in inspect("missing-selected-export", 1):
            raise AssertionError("a missing selected export was accepted")
        config.write_text(template + '\n[[bindings]]\nparticipant = "main"\ntype_name = "Common::Reading"\nprovider = "project_a"\n')
        if "DuplicateBinding" not in inspect("duplicate-selection", 1):
            raise AssertionError("equivalent exports implicitly replaced a binding")
        config.write_text(template.replace(original_binding, constrained))
        identity(inspect("constrained-equivalent-b"), "project_b")

        setup = [login(0), login(1), *graph(0), *graph(1)]
        # Truncated, wrong-type and trailing samples must fail without reaching DDS.
        setup += [write(0, 0, 0, b"\0", INVALID), write(0, 0, 0, sample(0, 0, 1), INVALID), write(0, 0, 2, sample(0, 0, 2) + b"x", INVALID)]
        setup += [(0, 1, create_reference(90, 0x4200, 2, "temperature", 0x1100), UNKNOWN)]
        recovery = [[], [(0, 12, b"", None), write(0, 1, 0, expected=UNKNOWN), write(1, 1, 1), *graph(0), login(1), *graph(1, MATCHED)], [login(0, 0x82), write(0, 2, 0, expected=UNKNOWN), write(1, 2, 1), *graph(0)]]
        rounds = 100
        writes = [[write(client, phase, kind) for _ in range(rounds) for client in range(2) for kind in range(3)] for phase in range(4)]
        final = [(0, 3, struct.pack("<HH", 100, 0xFEFF), OK)]
        # Hold client 0 idle beyond the five-second test policy while client 1
        # continues writing. Reconnect with the same key/session: its graph must
        # be absent, while client 1's CREATE/REUSE still matches its live graph.
        hold = [write(1, 2, 1) for _ in range(80)]
        recovery.append([login(0, 0x82), write(0, 3, 0, expected=UNKNOWN), *graph(0), *graph(1, MATCHED)])
        count = len(setup) + len(hold) + sum(map(len, recovery)) + sum(map(len, writes)) + len(final)
        server = Process([args.agent.resolve(), *base, "--port=0", "--client-idle-timeout-seconds=5", f"--max-datagrams={count}"], logs / "agent.log", ready="listening for DDS-XRCE UDP on port")
        clients = []
        consumer = None
        try:
            server.wait_ready()
            port = int(re.search(r"port (\d+)", "".join(server.lines)).group(1))
            clients = [Client(port), Client(port)]

            def execute(operations):
                for client, kind, payload, expected in operations:
                    clients[client].exchange(kind, payload, expected)

            execute(setup)
            for phase in range(4):
                if phase == 3:
                    for operation in hold:
                        execute([operation])
                        time.sleep(0.1)
                    output = "".join(server.lines)
                    if "released inactive client=01020301" not in output:
                        raise AssertionError("idle client was not reclaimed while its peer kept publishing")
                    if "released inactive client=01020302" in output:
                        raise AssertionError("active client expired")
                execute(recovery[phase])
                consumer = Process([args.consumer.resolve(), str(phase), *base], logs / f"consumer-{phase}.log", ready="multi-library consumer ready")
                consumer.wait_ready()
                for i in range(0, len(writes[phase]), 6):
                    execute(writes[phase][i:i + 6])
                    time.sleep(0.1)
                consumer.finish()
                if f"received all six project/client samples phase={phase}" not in "".join(consumer.lines):
                    raise AssertionError(f"missing DDS receipt for phase {phase}")
                consumer.close()
                consumer = None
            execute(final)
            if sum(client.sent for client in clients) != count:
                raise AssertionError("datagram budget mismatch")
            server.finish()
            if "ThreadSanitizer" in "".join(server.lines):
                raise AssertionError("agent sanitizer report")
        finally:
            if consumer:
                consumer.close()
            for client in clients:
                client.socket.close()
            server.close()
    print("PASS: independent libraries, explicit equivalent/conflicting exports, 24 DDS receipts, isolated clients, malformed samples, RESET/reconnect, idle expiry and live-graph shutdown")


if __name__ == "__main__":
    main()
