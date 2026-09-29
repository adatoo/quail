"""The engines compared, each behind the same small interface (ADR D-063).

An engine is started for one model at a time, with a scratch HOME and scratch model and cache folders, on a free
localhost port, and stopped (with everything it spawned) before the next one starts. Every engine serves the
model under the same id (`Model.served_id`), so the requests the benchmarks send are identical across engines.

Launch settings follow bench/config/fairness.toml: 8 slots of 8K context, full-precision KV cache, neutral
sampling pinned server-side where an engine has defaults of its own, thinking off.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import config, httpc
from .config import Model

BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


@dataclass
class Launch:
    """What starting an engine takes: the command, its environment, and the id to send as `model`."""

    argv: list[str]
    env: dict[str, str]
    served: str
    uses_key: bool = True
    files: dict[str, str] = field(default_factory=dict)  # scratch-relative path → contents, written before start


@dataclass
class Server:
    engine: "Engine"
    model: Model
    port: int
    key: str | None
    served: str
    workdir: Path
    log: Path
    process: subprocess.Popen
    env: dict[str, str] = field(default_factory=dict)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def chat_url(self) -> str:
        return f"{self.base}/v1/chat/completions"

    @property
    def messages_url(self) -> str:
        return f"{self.base}/v1/messages"


class EngineUnavailable(Exception):
    pass


class Engine:
    name = ""
    title = ""
    lane = ""
    ready_path = "/v1/models"
    start_timeout = 600.0

    # --- Where it is ---------------------------------------------------------------------------------------------

    def locate(self) -> Path:
        """The executable, or EngineUnavailable with what to do about it."""
        raise NotImplementedError

    def version(self) -> str:
        raise NotImplementedError

    # --- Starting and stopping -------------------------------------------------------------------------------------

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        raise NotImplementedError

    def request_fields(self, model: Model) -> dict:
        """Extra fields every request to this engine carries (thinking off, in the engine's own words)."""
        return {"chat_template_kwargs": {"enable_thinking": False}}

    def after_start(self, server: Server) -> None:
        """Anything that needs the server up before the model can load (an Ollama import)."""

    def load(self, server: Server) -> None:
        """Makes the model resident, so the first timed request doesn't pay for loading it."""
        tiny = {"model": server.served, "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 1}
        httpc.post(server.chat_url, dict(tiny, **self.request_fields(server.model)), key=server.key, timeout=900)

    def start(self, model: Model, run_dir: Path, log=print) -> Server:
        self.locate()  # fails early, saying what to do
        workdir = run_dir / "servers" / f"{self.name}--{model.id}"
        if workdir.exists():
            shutil.rmtree(workdir)
        for sub in ("home", "tmp", "hf"):
            (workdir / sub).mkdir(parents=True, exist_ok=True)
        port = free_port()
        key = secrets.token_urlsafe(16)
        launch = self.launch(model, workdir, port, key)
        for relative, contents in launch.files.items():
            path = workdir / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        env = {
            "PATH": BASE_PATH,
            "HOME": str(workdir / "home"),
            "TMPDIR": str(workdir / "tmp") + "/",
            "HF_HOME": str(workdir / "hf"),
            "HF_HUB_OFFLINE": "1",
            "LANG": "en_US.UTF-8",
        }
        env.update(launch.env)
        log_path = workdir / "server.log"
        (workdir / "launch.json").write_text(json.dumps({
            "engine": self.name,
            "model": model.id,
            "argv": [redact(arg, key) for arg in launch.argv],
            "env": {k: redact(v, key) for k, v in env.items()},
            "port": port,
        }, indent=2))
        switches = " ".join(f"{k}={v}" for k, v in launch.env.items() if k.startswith("QUAIL_"))
        log(f"  starting {self.title} with {model.name} on port {port}" + (f", with {switches}" if switches else ""))
        process = subprocess.Popen(
            launch.argv, env=env, cwd=workdir, stdin=subprocess.DEVNULL,
            stdout=open(log_path, "ab"), stderr=subprocess.STDOUT, start_new_session=True,
        )
        server = Server(self, model, port, key if launch.uses_key else None, launch.served, workdir, log_path, process,
                        env=env)
        try:
            self.wait_ready(server)
            self.after_start(server)
            started = time.perf_counter()
            self.load(server)
            (workdir / "load.json").write_text(json.dumps({"load_seconds": time.perf_counter() - started}))
        except BaseException:
            self.stop(server)
            raise
        return server

    def wait_ready(self, server: Server) -> None:
        deadline = time.monotonic() + self.start_timeout
        while time.monotonic() < deadline:
            if server.process.poll() is not None:
                raise RuntimeError(f"{self.title} exited during start-up (code {server.process.returncode}); "
                                   f"see {server.log}")
            if httpc.reachable(server.base + self.ready_path, key=server.key):
                return
            time.sleep(0.5)
        raise TimeoutError(f"{self.title} wasn't ready within {self.start_timeout:.0f} s; see {server.log}")

    def stop(self, server: Server) -> None:
        stop_group(server.process)
        wait_port_closed(server.port)
        discard_caches(server.workdir)


def discard_caches(workdir: Path) -> None:
    """Once a server has stopped, its scratch HOME, caches and model links go; its launch record, logs and settings
    files stay. oMLX's SSD cache and Rapid-MLX's saved prefix cache came to several GB per server, 45 GB in one
    trial run. A link is only unlinked, never followed: they point into the model store."""
    for child in workdir.iterdir():
        if child.is_symlink():
            child.unlink()
        elif child.is_dir():
            shutil.rmtree(child, ignore_errors=True)


# --- Quail and the llama-server it bundles --------------------------------------------------------------------------


def quail_app() -> Path:
    """A Release build of Quail: QUAIL_BENCH_APP, or the first of engines.toml's `apps` that exists."""
    configured = os.environ.get("QUAIL_BENCH_APP")
    candidates = [configured] if configured else config.load("engines")["quail"]["apps"]
    for candidate in candidates:
        app = Path(candidate).expanduser()
        if (app / "Contents/MacOS/quail-server").exists():
            if "/Debug/" in str(app.resolve()) or "/Debug-" in str(app.resolve()):
                raise EngineUnavailable(f"{app} is a Debug build (unoptimised); use a Release build: task install")
            return app
    raise EngineUnavailable("no Release Quail.app found; `task install`, or set QUAIL_BENCH_APP")


def quail_switches() -> dict[str, str]:
    """Quail's own switches set where the harness runs (`QUAIL_MLX_BATCH=0`, `QUAIL_PROMPT_LOOKUP=0`, …), passed
    to its server for an A/B run; the harness's own settings (QUAIL_BENCH_*) aren't. launch.json records them."""
    return {k: v for k, v in os.environ.items() if k.startswith("QUAIL_") and not k.startswith("QUAIL_BENCH_")}


def presets(model: Model, lane: str, served: str, fairness: dict, *, llama_server: bool = False) -> str:
    """The `--models-preset` section both Quail's server and llama-server read (ModelStore.regeneratePresets'
    format). For GGUF the context is one pool shared by every slot, as llama-server's unified KV cache is; for
    MLX each request has its own cache, so the context is per request."""
    slots = fairness["slots"]
    per_slot = fairness["context_per_slot"]
    lines = [f"[{served}]", f"model = {model.path(lane)}"]
    if lane == "gguf":
        lines += ["n-gpu-layers = 99", f"ctx-size = {slots * per_slot}", "flash-attn = on"]
        if llama_server:
            lines.append("kv-unified = true")
    else:
        lines.append(f"ctx-size = {per_slot}")
    lines += [f"parallel = {slots}", "load-on-startup = true"]
    return "\n".join(lines) + "\n"


class QuailEngine(Engine):
    ready_path = "/health"

    def __init__(self, lane: str):
        self.lane = lane
        self.name = f"quail-{lane}"
        self.title = f"Quail ({lane.upper()})"

    def locate(self) -> Path:
        return quail_app() / "Contents/MacOS/quail-server"

    def version(self) -> str:
        return run_text([str(self.locate()), "--version"]).replace("quail-server", "").strip()

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        fairness = config.fairness()
        served = model.served_id(self.lane)
        return Launch(
            argv=[
                str(self.locate()), "--host", "127.0.0.1", "--port", str(port),
                "--models-dir", str(workdir / "empty-gguf"), "--mlx-dir", str(workdir / "empty-mlx"),
                "--models-preset", str(workdir / "presets.ini"), "--models-max", "1",
                "--parallel", str(fairness["slots"]), "--no-prompt-cache-disk", "--no-webui",
                "--log-file", str(workdir / "quail-server.log"), "--api-key", key,
            ],
            env=quail_switches(),
            served=served,
            files={
                "presets.ini": presets(model, self.lane, served, fairness),
                "empty-gguf/.keep": "",
                "empty-mlx/.keep": "",
            },
        )

    def load(self, server: Server) -> None:
        load_router_model(server)


class LlamaServerEngine(Engine):
    name = "llama-server"
    title = "llama-server"
    lane = "gguf"
    ready_path = "/health"

    def locate(self) -> Path:
        return quail_app() / "Contents/MacOS/llama-server"

    def version(self) -> str:
        text = run_text([str(self.locate()), "--version"], merge=True)
        match = re.search(r"version: (.+)", text)
        return match.group(1).strip() if match else "unknown"

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        fairness = config.fairness()
        served = model.served_id(self.lane)
        return Launch(
            argv=[
                str(self.locate()), "--host", "127.0.0.1", "--port", str(port),
                "--models-dir", str(workdir / "empty-gguf"), "--models-max", "1",
                "--models-preset", str(workdir / "presets.ini"), "--no-webui",
                "--log-file", str(workdir / "llama-server-own.log"), "--api-key", key,
            ],
            env={},
            served=served,
            files={
                "presets.ini": presets(model, self.lane, served, fairness, llama_server=True),
                "empty-gguf/.keep": "",
            },
        )

    def load(self, server: Server) -> None:
        load_router_model(server)


def load_router_model(server: Server, timeout: float = 900) -> None:
    """Asks a router (quail-server, llama-server) to load the model, and waits until it says loaded."""
    try:
        httpc.post(f"{server.base}/models/load", {"model": server.served}, key=server.key, timeout=60)
    except httpc.HTTPError as error:
        if "already" not in error.body.lower():
            raise
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        models = httpc.get(f"{server.base}/models", key=server.key).get("data", [])
        entry = next((m for m in models if m.get("id") == server.served), None)
        status = (entry or {}).get("status", {})
        if status.get("value") == "loaded":
            return
        if status.get("failed"):
            raise RuntimeError(f"{server.engine.title} couldn't load {server.served}; see {server.log}")
        time.sleep(0.5)
    raise TimeoutError(f"{server.engine.title} didn't load {server.served} within {timeout:.0f} s")


# --- Ollama -----------------------------------------------------------------------------------------------------------


class OllamaEngine(Engine):
    ready_path = "/api/version"

    def __init__(self, lane: str):
        self.lane = lane
        self.name = f"ollama-{lane}"
        self.title = f"Ollama ({lane.upper()})"

    def locate(self) -> Path:
        version = config.load("engines")["ollama"]["version"]
        path = config.VENDOR / "bench" / f"ollama-{version}" / "ollama"
        if not path.exists():
            raise EngineUnavailable(f"Ollama {version} isn't staged; run: task vendor:ollama")
        return path

    def version(self) -> str:
        text = run_text([str(self.locate()), "--version"], env={"OLLAMA_HOST": "127.0.0.1:1"})
        match = re.search(r"version is v?([\w.\-]+)", text)
        return match.group(1) if match else "unknown"

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        fairness = config.fairness()
        return Launch(
            argv=[str(self.locate()), "serve"],
            env={
                "OLLAMA_HOST": f"127.0.0.1:{port}",
                # Shared by every run, but never the user's own ~/.ollama: imports are kept, so a second run
                # doesn't copy 20 GB again.
                "OLLAMA_MODELS": str(config.WORK / "ollama-models"),
                "OLLAMA_NUM_PARALLEL": str(fairness["slots"]),
                "OLLAMA_CONTEXT_LENGTH": str(fairness["context_per_slot"]),
                "OLLAMA_FLASH_ATTENTION": "1",
                "OLLAMA_KV_CACHE_TYPE": "f16",
                "OLLAMA_KEEP_ALIVE": "-1",
                "OLLAMA_MAX_LOADED_MODELS": "1",
                "OLLAMA_NOHISTORY": "1",
            },
            served=model.served_id(self.lane),
            uses_key=False,
            files={"Modelfile": self.modelfile(model, fairness)},
        )

    def modelfile(self, model: Model, fairness: dict) -> str:
        sampling = fairness["sampling"]
        return "\n".join([
            f"FROM {model.path(self.lane)}",
            f"PARAMETER num_ctx {fairness['context_per_slot']}",
            f"PARAMETER temperature {sampling['temperature']}",
            f"PARAMETER top_p {sampling['top_p']}",
            "PARAMETER repeat_penalty 1",
        ]) + "\n"

    def after_start(self, server: Server) -> None:
        """Imports the model from the same file or folder every other engine in the lane reads. The client gets the
        server's own environment: a safetensors (MLX) import is converted client-side and written straight into
        OLLAMA_MODELS, so a client without it would import into its own HOME instead."""
        done = subprocess.run(
            [str(self.locate()), "create", server.served, "-f", str(server.workdir / "Modelfile")],
            env=server.env, cwd=server.workdir, capture_output=True, text=True, timeout=3600,
        )
        (server.workdir / "create.log").write_text(done.stdout + done.stderr)
        if done.returncode != 0:
            raise RuntimeError(f"ollama create failed: {(done.stderr or done.stdout).strip()[-400:]}")

    def load(self, server: Server) -> None:
        httpc.post(f"{server.base}/api/generate", {"model": server.served, "keep_alive": -1}, timeout=900)

    def request_fields(self, model: Model) -> dict:
        # Ollama's OpenAI-compatible route takes reasoning_effort, not chat_template_kwargs. The smoke test checks
        # thinking really is off; capabilities.json records it if not.
        return {"reasoning_effort": "none"}


# --- oMLX -------------------------------------------------------------------------------------------------------------


class OMLXEngine(Engine):
    name = "omlx"
    title = "oMLX"
    lane = "mlx"

    def locate(self) -> Path:
        path = config.TOOLS / "omlx" / ".venv" / "bin" / "omlx"
        if not path.exists():
            raise EngineUnavailable("oMLX isn't installed for the harness; run: task bench:setup")
        return path

    def version(self) -> str:
        venv_python = self.locate().parent / "python"
        return run_text([str(venv_python), "-c", "import importlib.metadata as m; print(m.version('omlx'))"])

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        fairness = config.fairness()
        served = model.served_id(self.lane)
        models_dir = workdir / "omlx-models"
        models_dir.mkdir(parents=True, exist_ok=True)
        link = models_dir / served
        if not link.exists():
            link.symlink_to(model.mlx, target_is_directory=True)
        settings = {"version": 1, "models": {served: {
            "max_context_window": fairness["context_per_slot"],
            "enable_thinking": False,
            "turboquant_kv_enabled": False,
            "repetition_penalty": 1.0,
            "is_pinned": True,
        }}}
        return Launch(
            argv=[
                str(self.locate()), "serve", "--model-dir", str(models_dir), "--base-path", str(workdir / "omlx-base"),
                "--host", "127.0.0.1", "--port", str(port), "--api-key", key,
                "--max-concurrent-requests", str(fairness["slots"]),
                "--paged-ssd-cache-dir", str(workdir / "omlx-ssd"), "--log-level", "info",
            ],
            env={"PATH": f"{self.locate().parent}:{BASE_PATH}"},
            served=served,
            files={"omlx-base/model_settings.json": json.dumps(settings, indent=2)},
        )


# --- Rapid-MLX --------------------------------------------------------------------------------------------------------


class RapidMLXEngine(Engine):
    name = "rapid-mlx"
    title = "Rapid-MLX"
    lane = "mlx"

    def locate(self) -> Path:
        command = config.load("engines")["rapid-mlx"]["command"]
        found = shutil.which(command, path=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")
        if not found:
            raise EngineUnavailable(f"{command} isn't installed (brew install rapid-mlx)")
        return Path(found)

    def version(self) -> str:
        text = run_text([str(self.locate()), "--version"])
        return text.split()[-1] if text else "unknown"

    def launch(self, model: Model, workdir: Path, port: int, key: str) -> Launch:
        fairness = config.fairness()
        sampling = fairness["sampling"]
        served = model.served_id(self.lane)
        return Launch(
            argv=[
                str(self.locate()), "--no-banner", "--no-telemetry", "serve", str(model.mlx),
                "--served-model-name", served, "--host", "127.0.0.1", "--port", str(port), "--api-key", key,
                "--max-num-seqs", str(fairness["slots"]), "--stream-interval", "1",
                # The comparison is text only. Gemma 4 is a vision model, which Rapid-MLX would load through
                # mlx-vlm (not in its Homebrew build) and serve on its multimodal path.
                "--no-mllm",
                # Its model profiles can switch on a quantized or compressed KV cache and prompt compression by
                # themselves; the comparison holds every engine to a full-precision cache.
                "--kv-cache-dtype", "bf16", "--kv-cache-turboquant", "none", "--pflash", "off",
                "--default-temperature", str(sampling["temperature"]), "--default-top-p", str(sampling["top_p"]),
                "--default-repetition-penalty", "1.0",
                "--default-presence-penalty", str(sampling["presence_penalty"]),
                "--default-frequency-penalty", str(sampling["frequency_penalty"]),
                "--enable-auto-tool-choice", "--tool-call-parser", "auto",
                "--watchdog-ppid", str(os.getpid()),
            ],
            env={"PATH": f"{self.locate().parent}:{BASE_PATH}"},
            served=served,
        )


# --- The roster -------------------------------------------------------------------------------------------------------

ENGINES: dict[str, Engine] = {
    engine.name: engine
    for engine in [
        QuailEngine("gguf"), LlamaServerEngine(), OllamaEngine("gguf"),
        QuailEngine("mlx"), OMLXEngine(), RapidMLXEngine(), OllamaEngine("mlx"),
    ]
}


def select(names: str | None) -> list[Engine]:
    if not names:
        return list(ENGINES.values())
    wanted = [n.strip() for n in names.split(",") if n.strip()]
    unknown = [n for n in wanted if n not in ENGINES]
    if unknown:
        raise SystemExit(f"unknown engine(s) {', '.join(unknown)}; have: {', '.join(ENGINES)}")
    return [ENGINES[n] for n in wanted]


# --- Helpers ----------------------------------------------------------------------------------------------------------


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) == 0


def wait_port_closed(port: int, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while port_open(port) and time.monotonic() < deadline:
        time.sleep(0.2)


def stop_group(process: subprocess.Popen, grace: float = 20) -> None:
    """SIGTERM to the whole process group (the server and anything it spawned), then SIGKILL after `grace`."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)
    # Children that outlived the leader (Ollama's runners) are still in the group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def run_text(argv: list[str], env: dict | None = None, timeout: float = 30, merge: bool = False) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                              env=dict(os.environ, **(env or {})))
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if merge:
        return (done.stdout + "\n" + done.stderr).strip()
    return (done.stdout or done.stderr).strip()


def redact(value: str, key: str) -> str:
    return value.replace(key, "<key>") if key else value
