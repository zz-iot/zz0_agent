#!/usr/bin/env python3
"""Test the agent against an independently built eProsima client (localhost UDP)."""
import argparse
from pathlib import Path
import re
import subprocess
from process import Process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, type=Path)
    parser.add_argument("--prefix", required=True, type=Path, help="Independent client installation")
    parser.add_argument("--logs", required=True, type=Path)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    peer = args.logs.resolve() / "eprosima-client"
    subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                    f"-I{args.prefix / 'include'}", str(Path(__file__).with_name("peer.c")),
                    str(args.prefix / "lib/libmicroxrcedds_client.a"),
                    str(args.prefix / "lib/libmicrocdr.a"), "-o", str(peer)], check=True)
    server = Process([args.agent.resolve(), "--port=0", "--handshake=eprosima_v3", "--write-log=summary"],
                     args.logs / "agent.log", ready="listening for DDS-XRCE UDP on port")
    client = None
    try:
        server.wait_ready()
        port = re.search(r"port (\d+)", "".join(server.lines)).group(1)
        client = Process([peer, port], args.logs / "peer.log")
        client.finish()
    finally:
        if client:
            client.close()
        server.close()
    if "counter=42 board=eprosima payload_len=3 total_writes=1" not in "".join(server.lines):
        raise RuntimeError("Agent did not record the independent CounterStatus sample")
    print("PASS: independent session, four creates, sample acceptance and negative statuses")


if __name__ == "__main__":
    main()
