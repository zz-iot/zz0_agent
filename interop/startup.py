#!/usr/bin/env python3
"""Exercise configuration modes and startup failures through the real executable."""
import argparse
import hashlib
from pathlib import Path
import socket
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--offline-only", action="store_true")
    args = parser.parse_args()
    agent = args.agent.resolve()
    original = args.config.resolve()
    library = args.library.resolve() if args.library else None
    if not args.offline_only and library is None:
        parser.error("--library is required unless --offline-only")
    with tempfile.TemporaryDirectory(prefix="zz0-startup-") as directory:
        root = Path(directory)
        config_dir = root / "config"
        config_dir.mkdir()
        config = config_dir / "agent.toml"
        resources = config_dir / "resources.toml"
        text = original.read_text()
        config.write_text("_future_option = true\n" + text)
        resources.write_text((original.parent / "resources.toml").read_text())

        def run(options, expected=0, contains=None):
            result = subprocess.run([str(agent), *map(str, options)], cwd=root,
                                    text=True, capture_output=True, timeout=30)
            output = result.stdout + result.stderr
            if result.returncode != expected or (contains and contains not in output):
                raise AssertionError(f"{options}: exit={result.returncode}\n{output}")
            if "listening for DDS-XRCE UDP" in output:
                raise AssertionError(f"unexpected readiness for {options}\n{output}")
            if "ThreadSanitizer" in output or "stack trace" in output:
                raise AssertionError(output)
            return output

        run(["--help"], contains="usage:")
        run(["--version"], contains="zz0_agent ")
        run([], 1, "ConfigRequired")
        run(["--validate-only"], 1, "UnknownArgument")
        base = ["--config", config]
        absent = ["--library", "counter=/no-such-provider"]
        output = run([*base, *absent, "--check-config"], contains="remain unchecked")
        if f"{config}:1:1: skipped optional setting _future_option" not in output:
            raise AssertionError("optional-setting diagnostic missing")
        run([*base, *absent, "--check-config", "--sha256", "counter=" + "00" * 32], contains="offline configuration valid")
        run([*base, *absent, "--inspect"], 1, "FileNotFound")
        run([*base, "--check-config"], 1, "bindings.0.provider")
        config.write_text(text.replace("kind = \"datawriter\"", "kind = 'not_a_kind'"))
        run([*base, *absent, "--check-config"], 1, "catalog.MyLibrary::CounterStatusWriter.kind")
        config.write_text(text)
        resources.write_text("schema_version = 1\nnot_a_resource_field = true\n")
        run([*base, *absent, "--check-config"], 1, f"{resources}:2:")
        resources.write_text((original.parent / "resources.toml").read_text())
        if args.offline_only:
            print("PASS: CLI modes, offline checks, optional settings and source diagnostics; no providers needed")
            return
        # A relative library path resolves from the invocation, while resources
        # resolve from the manifest's separate directory.
        link = root / "provider"
        link.symlink_to(library)
        loaded = [*base, "--library", "counter=provider"]
        digest = hashlib.sha256(library.read_bytes()).hexdigest()
        run([*loaded, "--inspect", "--sha256", "counter=" + digest], contains="wire_validation=true")
        run([*loaded, "--inspect", "--sha256", "counter=" + "00" * 32], 1, "ArtifactHashMismatch")
        config.write_text(text.replace('provider = "counter"', 'provider = "counter"\nexpected_identifier = "f1' + "00" * 14 + '"'))
        run([*loaded, "--inspect"], 1, "TypeIdentityMismatch")
        config.write_text(text)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
            occupied.bind(("0.0.0.0", 0))
            port = occupied.getsockname()[1]
            run([*loaded, "--inspect", f"--port={port}"], contains="no DDS factory, entities or UDP listener")
            run([*loaded, f"--port={port}"], 1, "AddressInUse")
        print("PASS: loaded inspection, artifact/identity rejection, path bases and failed-bind rollback")


if __name__ == "__main__":
    main()
