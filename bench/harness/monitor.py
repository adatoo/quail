"""What a server costs while it's measured: its memory footprint and the Mac's power draw, sampled about once a
second (ADR D-063).

Memory is `footprint`'s figure for every process in the server's process group, summed: that counts the GPU
buffers Metal holds (`IOAccelerator`), which resident size doesn't. Power is powermetrics' combined CPU, GPU and
ANE figure, so it needs the same passwordless sudo as the thermal gate; without it the run records none.
"""

from __future__ import annotations

import json
import re
import signal
import statistics
import subprocess
import threading
import time
from pathlib import Path

FOOTPRINT = re.compile(r"Footprint:\s*(\d+)\s*B")
COMBINED = re.compile(r"Combined Power \(CPU \+ GPU \+ ANE\):\s*(\d+)\s*mW")


def group_pids(pgid: int) -> list[int]:
    out = subprocess.run(["ps", "-axo", "pid=,pgid="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == str(pgid):
            pids.append(int(parts[0]))
    return pids


def footprint_bytes(pids: list[int]) -> int | None:
    if not pids:
        return None
    argv = ["/usr/bin/footprint", "-f", "bytes", "--noCategories"]
    for pid in pids:
        argv += ["-p", str(pid)]
    out = subprocess.run(argv, capture_output=True, text=True).stdout
    values = [int(v) for v in FOOTPRINT.findall(out)]
    return sum(values) if values else None


def parse_power(text: str) -> list[float]:
    """Watts, one per powermetrics sample in `text`."""
    return [int(mw) / 1000 for mw in COMBINED.findall(text)]


class Monitor:
    """Samples in the background from `start()` to `stop()`; `stop()` returns the summary."""

    def __init__(self, pgid: int, out: Path, interval: float = 1.0):
        self.pgid = pgid
        self.out = out
        self.interval = interval
        self.memory: list[tuple[float, int]] = []
        self.watts: list[float] = []
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._power: subprocess.Popen | None = None
        self.started = 0.0

    def start(self) -> Monitor:
        self.started = time.monotonic()
        memory = threading.Thread(target=self._sample_memory, daemon=True)
        memory.start()
        self._threads.append(memory)
        try:
            self._power = subprocess.Popen(
                ["sudo", "-n", "/usr/bin/powermetrics", "--samplers", "cpu_power,gpu_power",
                 "-i", str(int(self.interval * 1000))],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
            power = threading.Thread(target=self._read_power, daemon=True)
            power.start()
            self._threads.append(power)
        except OSError:
            self._power = None
        return self

    def _sample_memory(self) -> None:
        while not self._stop.is_set():
            value = footprint_bytes(group_pids(self.pgid))
            if value is not None:
                self.memory.append((round(time.monotonic() - self.started, 2), value))
            self._stop.wait(self.interval)

    def _read_power(self) -> None:
        assert self._power and self._power.stdout
        for line in self._power.stdout:
            self.watts += parse_power(line)

    def stop(self) -> dict:
        self._stop.set()
        if self._power:
            self._power.send_signal(signal.SIGTERM)
            try:
                self._power.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._power.kill()
        for thread in self._threads:
            thread.join(timeout=5)
        seconds = time.monotonic() - self.started
        summary = summarise(self.memory, self.watts, seconds)
        self.out.write_text(json.dumps({"summary": summary, "memory": self.memory, "watts": self.watts}))
        return summary


def summarise(memory: list[tuple[float, int]], watts: list[float], seconds: float) -> dict:
    values = [v for _, v in memory]
    return {
        "seconds": round(seconds, 1),
        "peak_footprint_bytes": max(values) if values else None,
        "median_footprint_bytes": int(statistics.median(values)) if values else None,
        "mean_watts": round(statistics.fmean(watts), 2) if watts else None,
        "power_samples": len(watts),
    }
