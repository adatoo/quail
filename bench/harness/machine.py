"""The Mac under test: what else is running, how hot it is, and quieting it for a timed run (ADR D-063).

Everything paused here is recorded in a state file first, and put back by `restore()` — on a normal exit, on
Ctrl-C and on SIGTERM/SIGHUP, and by `task bench:restore` if the driver itself was killed.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path

from . import config

# Servers that would compete for the GPU and memory during a timed run. The harness never stops these itself.
COMPETITORS = {
    "Quail": re.compile(r"/Quail\.app/Contents/MacOS/Quail$"),
    "quail-server": re.compile(r"(^|/)quail-server$"),
    "llama-server": re.compile(r"(^|/)llama-server$"),
    "ollama": re.compile(r"(^|/)(ollama|Ollama)$"),
    "omlx": re.compile(r"(^|/)omlx$|omlx(\.cli)? serve"),
    "rapid-mlx": re.compile(r"(^|/)rapid-mlx$|vllm_mlx|rapid_mlx"),
}

# Background analysis that used 3+ cores on the reference Mac while it was otherwise idle.
DAEMONS = ["mediaanalysisd", "photoanalysisd", "corespotlightd"]

PRESSURE_ORDER = ["Nominal", "Moderate", "Heavy", "Trapping", "Sleeping"]

STATE = config.WORK / "machine-state.json"


def processes() -> list[tuple[int, str, str]]:
    """(pid, executable path, full command line) for every process. Two ps calls, because either column can hold
    spaces ("Application Support"), so they can't share a line."""

    def column(name: str) -> dict[int, str]:
        out = subprocess.run(["ps", "-axo", f"pid=,{name}="], capture_output=True, text=True, check=True).stdout
        result = {}
        for line in out.splitlines():
            pid, _, rest = line.strip().partition(" ")
            if pid.isdigit():
                result[int(pid)] = rest.strip()
        return result

    executables, commands = column("comm"), column("args")
    return [(pid, executable, commands.get(pid, executable)) for pid, executable in executables.items()]


def competing_servers(ignore: set[int] | None = None) -> list[str]:
    """Names and pids of any other LLM servers running now."""
    ignore = ignore or set()
    found = []
    for pid, executable, args in processes():
        if pid in ignore or pid == os.getpid():
            continue
        for name, pattern in COMPETITORS.items():
            if pattern.search(executable) or pattern.search(args):
                found.append(f"{name} (pid {pid})")
                break
    return found


def pressure() -> str | None:
    """The thermal pressure level ("Nominal", "Moderate", …), or None if it can't be read without a password."""
    try:
        out = subprocess.run(
            ["sudo", "-n", "/usr/bin/powermetrics", "--samplers", "thermal", "-n", "1", "-i", "1"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_pressure(out.stdout) if out.returncode == 0 else None


def parse_pressure(text: str) -> str | None:
    match = re.search(r"Current pressure level:\s*(\w+)", text)
    return match.group(1) if match else None


def hotter(level: str | None, than: str) -> bool:
    if level not in PRESSURE_ORDER:
        return False
    return PRESSURE_ORDER.index(level) > PRESSURE_ORDER.index(than)


def wait_until_cool(settings: dict, log=print) -> str | None:
    """Waits (up to `max_wait_seconds`) for `wait_for` pressure, then rests. Returns the level it started at."""
    want = settings.get("wait_for", "Nominal")
    deadline = time.monotonic() + settings.get("max_wait_seconds", 900)
    level = pressure()
    if level is None:
        log("  (thermal pressure unreadable: needs passwordless sudo for /usr/bin/powermetrics; not waiting)")
        return None
    announced = False
    while hotter(level, want) and time.monotonic() < deadline:
        if not announced:
            log(f"  waiting for the Mac to cool ({level} → {want})…")
            announced = True
        time.sleep(5)
        level = pressure()
    time.sleep(settings.get("rest_seconds", 10))
    return level


def power() -> dict:
    """Power source and Low Power Mode, from pmset."""
    source = subprocess.run(["pmset", "-g", "ps"], capture_output=True, text=True).stdout
    settings = subprocess.run(["pmset", "-g"], capture_output=True, text=True).stdout
    low = re.search(r"lowpowermode\s+(\d)", settings)
    return {
        "ac": "AC Power" in source,
        "battery": "InternalBattery" in source,
        "low_power_mode": bool(low and low.group(1) == "1"),
    }


def time_machine_running() -> bool:
    out = subprocess.run(["tmutil", "status"], capture_output=True, text=True).stdout
    return bool(re.search(r"Running\s*=\s*1", out))


def spotlight_volumes() -> dict[str, bool]:
    """Volume → whether Spotlight indexing is on."""
    out = subprocess.run(["mdutil", "-a", "-s"], capture_output=True, text=True).stdout
    return parse_mdutil(out)


def parse_mdutil(text: str) -> dict[str, bool]:
    volumes: dict[str, bool] = {}
    current = None
    for line in text.splitlines():
        if line.startswith("/") and line.rstrip().endswith(":"):
            current = line.rstrip()[:-1]
        elif current and "Indexing enabled" in line:
            volumes[current] = True
        elif current and "Indexing disabled" in line:
            volumes[current] = False
    return volumes


# --- Quieting the Mac, and putting it back -----------------------------------------------------------------------


def _save(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


def quiet(log=print) -> None:
    """Pauses the analysis daemons and Spotlight for the run, recording what to restore first."""
    state = {"paused": [], "spotlight": {}}
    if STATE.exists():
        restore(log)
    for pid, comm, _ in processes():
        if Path(comm).name in DAEMONS:
            state["paused"].append(pid)
    volumes = spotlight_volumes()
    state["spotlight"] = {volume: on for volume, on in volumes.items() if on}
    _save(state)
    for pid in state["paused"]:
        try:
            os.kill(pid, signal.SIGSTOP)
        except (ProcessLookupError, PermissionError):
            pass
    if state["paused"]:
        log(f"  paused {len(state['paused'])} background analysis processes")
    for volume in state["spotlight"]:
        done = subprocess.run(["sudo", "-n", "/usr/bin/mdutil", "-i", "off", volume], capture_output=True)
        if done.returncode != 0:
            log(f"  (couldn't pause Spotlight on {volume}: needs passwordless sudo for /usr/bin/mdutil)")
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, _restore_and_exit)


def _restore_and_exit(signum, _frame) -> None:
    restore()
    raise SystemExit(128 + signum)


def restore(log=print) -> None:
    """Resumes whatever `quiet()` paused. Safe to call twice, and from `task bench:restore`."""
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text())
    for pid in state.get("paused", []):
        try:
            os.kill(pid, signal.SIGCONT)
        except (ProcessLookupError, PermissionError):
            pass
    for volume in state.get("spotlight", {}):
        subprocess.run(["sudo", "-n", "/usr/bin/mdutil", "-i", "on", volume], capture_output=True)
    STATE.unlink(missing_ok=True)
    log("  restored background processes and Spotlight")


def keep_awake() -> subprocess.Popen:
    """Stops idle and system sleep for as long as this process lives."""
    return subprocess.Popen(["caffeinate", "-i", "-s", "-w", str(os.getpid())])


def describe() -> dict:
    """The facts the report records about the Mac."""

    def sysctl(name: str) -> str:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()

    return {
        "chip": sysctl("machdep.cpu.brand_string"),
        "model": sysctl("hw.model"),
        "memory_bytes": int(sysctl("hw.memsize") or 0),
        "performance_cores": int(sysctl("hw.perflevel0.physicalcpu") or 0),
        "efficiency_cores": int(sysctl("hw.perflevel1.physicalcpu") or 0),
        "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
        "power": power(),
        "thermal": pressure(),
    }
