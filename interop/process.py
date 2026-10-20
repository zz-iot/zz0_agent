"""Bounded subprocess handling with complete logs, readiness and cleanup."""
from pathlib import Path
import subprocess
import threading


class Process:
    def __init__(self, command, log, ready=None):
        self.command = [str(arg) for arg in command]
        self.log = Path(log)
        self.log.parent.mkdir(parents=True, exist_ok=True)
        self.ready_text = ready
        self.ready = threading.Event()
        self.lines = []
        self.process = subprocess.Popen(self.command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, encoding="utf-8", errors="replace")
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        with self.log.open("w") as output:
            for line in self.process.stdout:
                self.lines.append(line)
                output.write(line)
                output.flush()
                if self.ready_text and self.ready_text in line:
                    self.ready.set()
        self.process.stdout.close()

    def wait_ready(self, seconds=10):
        if not self.ready.wait(seconds):
            raise RuntimeError(f"No readiness from {self.command}; see {self.log}")

    def finish(self, seconds=20):
        code = self.process.wait(timeout=seconds)
        self.reader.join(timeout=2)
        if code:
            raise RuntimeError(f"Exit {code}: {self.command}; see {self.log}\n{''.join(self.lines)}")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.reader.join(timeout=2)
