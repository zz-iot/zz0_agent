#!/usr/bin/env python3
"""Host XRCE -> UDP agent -> DDS consumer smoke test (not vendor interop evidence)."""
import argparse
from pathlib import Path
import re
import socket
import struct
import subprocess
import time


def string(value):
    data = value.encode() + b"\0"
    return struct.pack("<I", len(data)) + data


def create_reference(request, object_id, kind, name, parent):
    payload = struct.pack("<HHBB", request, object_id, kind, 1) + b"\0\0" + string(name)
    if kind == 1:
        payload += b"\0" * (-len(payload) % 2)
        payload += struct.pack("<h", parent)
    else:
        payload += struct.pack("<H", parent)
    return payload


def create_binary(request, object_id, kind, body, parent):
    # IDL outer sequence length, modern XTypes 1.3 delimiter, then parent ID.
    binary = struct.pack("<I", len(body)) + body
    return struct.pack("<HHBB", request, object_id, kind, 3) + b"\0\0" + struct.pack("<I", len(binary)) + binary + struct.pack("<H", parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--library", required=True, help="alias=path")
    parser.add_argument("--consumer", required=True, type=Path)
    parser.add_argument("--logs", required=True, type=Path)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    agent_log = args.logs / "agent-dds.log"
    consumer_log = args.logs / "consumer.log"
    processes = []
    with agent_log.open("w") as agent_out, consumer_log.open("w") as consumer_out:
        try:
            consumer = subprocess.Popen([str(args.consumer.resolve()), "--board=agent-smoke", "--count=3", "--timeout=15"], stdout=consumer_out, stderr=consumer_out)
            processes.append(consumer)
            agent = subprocess.Popen([str(args.agent.resolve()), "--config", str(args.config.resolve()), "--library", args.library, "--port=0", "--max-datagrams=107"], stdout=agent_out, stderr=agent_out)
            processes.append(agent)
            deadline = time.monotonic() + 10
            port = None
            while time.monotonic() < deadline:
                match = re.search(r"listening for DDS-XRCE UDP on port (\d+)", agent_log.read_text())
                if match:
                    port = int(match.group(1))
                    break
                if agent.poll() is not None:
                    raise RuntimeError("agent exited during startup")
                time.sleep(0.02)
            if port is None:
                raise TimeoutError("agent startup")
            if "DDS forwarding enabled (configured providers)" not in agent_log.read_text():
                raise RuntimeError("configured agent did not select DDS forwarding")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(5)
                sequence = 0

                def exchange(kind, payload, login=False):
                    nonlocal sequence
                    session, stream = (0x80, 0) if login else (0x81, 1)
                    flags = 3 if kind == 1 else 1  # CREATE REUSE; no live REPLACE.
                    wire = struct.pack("<BBHBBH", session, stream, sequence, kind, flags, len(payload)) + payload
                    sequence += 1
                    client.sendto(wire, ("127.0.0.1", port))
                    reply, _ = client.recvfrom(512)
                    if login:
                        if len(reply) != 17 or reply[4] != 4 or reply[8:12] != b"XRCE":
                            raise RuntimeError(f"unexpected login response: {reply.hex()}")
                    elif len(reply) != 14 or reply[4] != 5 or reply[8:12] != payload[:4] or reply[12] not in (0, 1):
                        raise RuntimeError(f"request {kind} rejected: {reply.hex()}")

                exchange(0, b"XRCE\x01\x00ZZ\x01\x02\x03\x04\x81\x00", login=True)
                exchange(1, create_reference(1, 0x1100, 1, "MyLibrary::CounterParticipant", 0))
                exchange(1, create_reference(2, 0x1200, 2, "MyLibrary::CounterStatusTopic", 0x1100))
                exchange(1, create_binary(3, 0x1300, 3, b"\x01\0\0\0" + string("pub") + b"\0", 0x1100))
                exchange(1, create_binary(4, 0x1500, 5, string("CounterStatusTopic") + b"\0", 0x1300))
                # Allow discovery, then send bounded best-effort samples. Receipt
                # is verified by the separate consumer, never inferred from STATUS.
                time.sleep(0.5)
                for counter in range(100):
                    sample = struct.pack("<I", counter) + string("agent-smoke")
                    sample += b"\0" * (-len(sample) % 4) + struct.pack("<I", 3) + b"\x01\x02\x03"
                    exchange(7, struct.pack("<HH", 5 + counter, 0x1500) + sample)
                    time.sleep(0.1)
                # RESET has no reply; the following correlated STATUS must not
                # be displaced by an accidental zero-length UDP datagram.
                client.sendto(struct.pack("<BBHBBH", 0x81, 1, sequence, 12, 1, 0), ("127.0.0.1", port))
                sequence += 1
                exchange(3, struct.pack("<HH", 105, 0xFEFF))  # delete this ProxyClient
            if consumer.wait(timeout=20) != 0:
                raise RuntimeError("DDS consumer failed")
            if agent.wait(timeout=20) != 0:
                raise RuntimeError("bounded agent shutdown failed")
            text = consumer_log.read_text()
            if "received 3 samples" not in text or text.count("sample board=agent-smoke") < 3 or "payload=010203" not in text:
                raise RuntimeError("missing decoded DDS evidence")
            print("XRCE -> agent -> DDS: three CounterStatus samples received; RESET, client deletion and bounded shutdown passed")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
