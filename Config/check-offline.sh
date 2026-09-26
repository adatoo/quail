#!/bin/bash
# Proves Quail works with no internet connection (ADR D-051). Everything runs under sandbox-exec with
# outbound IP connections denied:
#
#   1. quail-server, GGUF and MLX: denied *and fatal* — any attempt to reach beyond this Mac kills the
#      server. Loopback stays open: llama-server's router talks to its own model processes over it.
#   2. llama-server, GGUF: the same.
#   3. The whole Debug app, on a scratch data root (QUAIL_DATA_ROOT) with models cloned from the real
#      store: connections denied (only loopback allowed), not fatal, since the app's two background
#      checks (catalog refresh, Sparkle) are expected to try and fail quietly. Every control command a
#      `quail` user relies on must still work, and `pull` must fail fast with an offline message.
#   4. Coding tools started from the scratch app's own launch recipes (opencode, codex, claude, when
#      installed), in the same sandbox, must answer.
#
# The real app, config, models and socket are never touched. Needs a Debug build (task build).
#
#   task check:offline
#   GGUF_MODEL=… MLX_MODEL=… SKIP_TOOLS=1 Config/check-offline.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${QUAIL_APP:-$ROOT/DerivedData/Build/Products/Debug/Quail.app}"
SERVER="$APP/Contents/MacOS/quail-server"
LLAMA="$APP/Contents/MacOS/llama-server"
STORE="${STORE:-$HOME/Library/Application Support/Quail/Models}"
PORT="${PORT:-18979}"
APP_PORT="${APP_PORT:-18981}"
[ -x "$SERVER" ] || { echo "error: no Debug build at $APP; run task build (or set QUAIL_APP)" >&2; exit 1; }

# The smallest GGUF and MLX models in the store, unless named.
GGUF_MODEL="${GGUF_MODEL:-$(ls -S "$STORE/gguf" 2>/dev/null | grep -v mmproj | grep '\.gguf$' | tail -1 | sed 's/\.gguf$//')}"
MLX_MODEL="${MLX_MODEL:-$(cd "$STORE/mlx" 2>/dev/null && du -sk -- * 2>/dev/null | sort -n | head -1 | cut -f2)}"
[ -n "$GGUF_MODEL" ] || { echo "error: no GGUF model in $STORE/gguf" >&2; exit 1; }

# Short: the app's control socket path must fit sun_path (104 bytes).
WORK="$(mktemp -d /tmp/quail-offline.XXXX)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in "${PIDS[@]}"; do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
pass() { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
check() { # check "label" command…
  local label="$1"; shift
  if "$@" > "$WORK/last.out" 2>&1; then pass "$label"; else fail "$label"; sed 's/^/      /' "$WORK/last.out" | tail -5; fi
}

cat > "$WORK/strict.sb" <<'SB'
(version 1)
(allow default)
(deny network-outbound (remote ip) (with send-signal SIGKILL))
(allow network-outbound (remote ip "localhost:*"))
SB
cat > "$WORK/offline.sb" <<'SB'
(version 1)
(allow default)
(deny network-outbound (remote ip))
(allow network-outbound (remote ip "localhost:*"))
SB

echo "==> Control: the sandbox blocks the internet and allows loopback"
if sandbox-exec -f "$WORK/offline.sb" /usr/bin/curl -sS -m 5 -o /dev/null https://huggingface.co > /dev/null 2>&1; then
  echo "error: the sandbox let a connection out; this check would prove nothing" >&2; exit 1
fi
pass "https://huggingface.co is unreachable inside the sandbox"

# A scratch store: APFS clones of the real models (no extra disk space), small contexts.
mkdir -p "$WORK/models/gguf" "$WORK/models/mlx"
cp -c "$STORE/gguf/$GGUF_MODEL.gguf" "$WORK/models/gguf/"
{
  printf '[%s]\nmodel = %s\nn-gpu-layers = 99\nctx-size = 8192\n\n' "$GGUF_MODEL" "$WORK/models/gguf/$GGUF_MODEL.gguf"
} > "$WORK/gguf.ini"
cp "$WORK/gguf.ini" "$WORK/all.ini"
if [ -n "$MLX_MODEL" ]; then
  cp -cR "$STORE/mlx/$MLX_MODEL" "$WORK/models/mlx/"
  printf '[%s]\nmodel = %s\nctx-size = 8192\n' "$MLX_MODEL" "$WORK/models/mlx/$MLX_MODEL" >> "$WORK/all.ini"
fi

wait_health() { # wait_health port pid
  for _ in $(seq 1 150); do
    curl -sf -m 1 "localhost:$1/health" > /dev/null && return 0
    kill -0 "$2" 2>/dev/null || return 1
    sleep 0.2
  done
  return 1
}

chat() { # chat port model — a non-streamed chat that must say pong
  curl -sf -m 300 "localhost:$1/v1/chat/completions" -H 'content-type: application/json' \
    -d "{\"model\":\"$2\",\"temperature\":0,\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"/no_think Reply with the single word pong\"}]}" \
    | grep -qi pong
}
stream() { # stream port model — a streamed chat that ends with [DONE]
  curl -sfN -m 300 "localhost:$1/v1/chat/completions" -H 'content-type: application/json' \
    -d "{\"model\":\"$2\",\"stream\":true,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"/no_think Say hi\"}]}" \
    | grep -q '\[DONE\]'
}
messages() { # messages port model — Anthropic Messages API, as Claude Code uses
  curl -sf -m 300 "localhost:$1/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"$2\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"/no_think Reply with the single word pong\"}]}" \
    | grep -qi pong
}
page() { curl -sf --compressed -m 10 "localhost:$1/" | grep -qi "<html"; } # llama-server serves its page gzipped only
models() { curl -sf -m 10 "localhost:$1/v1/models" | grep -q "$2"; }
alive() { kill -0 "$1" 2>/dev/null; }

echo "==> quail-server, every outbound connection fatal (GGUF $GGUF_MODEL${MLX_MODEL:+, MLX $MLX_MODEL})"
sandbox-exec -f "$WORK/strict.sb" "$SERVER" --host 127.0.0.1 --port "$PORT" --models-dir "$WORK/models/gguf" \
  --mlx-dir "$WORK/models/mlx" --models-max 1 --models-preset "$WORK/all.ini" --log-file "$WORK/quail-server.log" \
  > "$WORK/quail-server.out" 2>&1 &
QS=$!; PIDS+=("$QS")
if wait_health "$PORT" "$QS"; then
  check "starts and answers /health" true
  check "/v1/models lists $GGUF_MODEL" models "$PORT" "$GGUF_MODEL"
  check "the chat page loads" page "$PORT"
  check "GGUF chat" chat "$PORT" "$GGUF_MODEL"
  check "GGUF streamed chat" stream "$PORT" "$GGUF_MODEL"
  check "GGUF /v1/messages" messages "$PORT" "$GGUF_MODEL"
  if [ -n "$MLX_MODEL" ]; then
    check "MLX chat" chat "$PORT" "$MLX_MODEL"
    check "MLX streamed chat" stream "$PORT" "$MLX_MODEL"
    check "MLX /v1/messages" messages "$PORT" "$MLX_MODEL"
  else
    echo "  - no MLX model in the store; MLX skipped"
  fi
  check "never tried to connect (still running)" alive "$QS"
else
  fail "quail-server didn't start, or was killed for connecting"; tail -5 "$WORK/quail-server.out"
fi
kill "$QS" 2>/dev/null; wait "$QS" 2>/dev/null

if [ -x "$LLAMA" ]; then
  echo "==> llama-server, every outbound connection fatal (GGUF $GGUF_MODEL)"
  (cd "$(dirname "$LLAMA")" && exec sandbox-exec -f "$WORK/strict.sb" "$LLAMA" --host 127.0.0.1 --port "$PORT" \
    --models-dir "$WORK/models/gguf" --models-max 1 --models-preset "$WORK/gguf.ini" \
    --log-file "$WORK/llama-server.log") > "$WORK/llama-server.out" 2>&1 &
  LS=$!; PIDS+=("$LS")
  if wait_health "$PORT" "$LS"; then
    check "the web UI loads" page "$PORT"
    check "GGUF chat" chat "$PORT" "$GGUF_MODEL"
    check "never tried to connect (still running)" alive "$LS"
  else
    fail "llama-server didn't start, or was killed for connecting"; tail -5 "$WORK/llama-server.out"
  fi
  kill "$LS" 2>/dev/null; wait "$LS" 2>/dev/null
fi

echo "==> The app, offline, on a scratch data root (loopback only)"
DATA="$WORK/data"
SUPPORT="$DATA/Application Support/Quail"
mkdir -p "$SUPPORT/Models"
cp -cR "$WORK/models/gguf" "$WORK/models/mlx" "$SUPPORT/Models/"
cat > "$SUPPORT/config.json" <<JSON
{"host":"127.0.0.1","port":$APP_PORT,"modelsMax":1,"runtimeID":"quail","apiKeyEnabled":false,
 "apiKeyDefaultApplied":true,"openAtLogin":false,"autoStartServer":true}
JSON
QUAIL_DATA_ROOT="$DATA" sandbox-exec -f "$WORK/offline.sb" "$APP/Contents/MacOS/Quail" > "$WORK/app.out" 2>&1 &
APPPID=$!; PIDS+=("$APPPID")

control() { # control '{"command":"status"}' — one request over the scratch app's socket; prints the reply
  /usr/bin/python3 - "$SUPPORT/control.sock" "$1" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(900)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
print(buf.decode().strip())
PY
}
ok() { control "$1" | /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); sys.exit(0 if r.get("ok") else (print(r.get("error")) or 1))'; }
field() { control "$1" | /usr/bin/python3 -c "import json,sys; r=json.load(sys.stdin); print($2)"; }

for _ in $(seq 1 100); do [ -S "$SUPPORT/control.sock" ] && break; sleep 0.2; done
READY=""
for _ in $(seq 1 150); do
  READY="$(field '{"command":"status"}' 'r["status"]["phase"]' 2>/dev/null)"
  [ "$READY" = ready ] && break
  sleep 0.2
done
if [ "$READY" = ready ]; then pass "opens and starts its server (status: ready)"; else fail "the app's server isn't ready (status: ${READY:-no answer})"; tail -5 "$WORK/app.out"; fi
check "quail list" ok '{"command":"list"}'
check "quail ps" ok '{"command":"ps"}'
check "quail config" ok '{"command":"config"}'
check "quail default $GGUF_MODEL" ok "{\"command\":\"setDefault\",\"model\":\"$GGUF_MODEL\"}"
check "quail ctx $GGUF_MODEL" ok "{\"command\":\"context\",\"model\":\"$GGUF_MODEL\"}"
check "chat through the app's endpoint (GGUF)" chat "$APP_PORT" "$GGUF_MODEL"
[ -n "$MLX_MODEL" ] && check "chat through the app's endpoint (MLX)" chat "$APP_PORT" "$MLX_MODEL"
check "quail bench $GGUF_MODEL" ok "{\"command\":\"bench\",\"model\":\"$GGUF_MODEL\"}"
START=$(date +%s)
PULL="$(field '{"command":"pull","model":"qwen3-4b"}' 'r.get("error") or ("ok" if r.get("ok") else "")' 2>&1)"
ELAPSED=$(( $(date +%s) - START ))
if echo "$PULL" | grep -qi "internet" && [ "$ELAPSED" -le 30 ]; then
  pass "quail pull fails in ${ELAPSED}s, saying why: $PULL"
else
  fail "quail pull should fail fast with an offline message (${ELAPSED}s): $PULL"
fi
check "the app is still running" alive "$APPPID"

if [ -z "${SKIP_TOOLS:-}" ]; then
  echo "==> Coding tools from the app's launch recipes, offline"
  run_tool() { # run_tool tool args-after-recipe…
    local tool="$1"; shift
    local recipe="$WORK/$tool.json"
    control "{\"command\":\"launch\",\"tool\":\"$tool\",\"model\":\"$GGUF_MODEL\"}" > "$recipe"
    /usr/bin/python3 - "$recipe" "$WORK/offline.sb" "$@" <<'PY'
import json, os, subprocess, sys
r = json.load(open(sys.argv[1]))
if not r.get("ok"):
    sys.exit(r.get("error"))
l = r["launch"]
env = dict(os.environ, **l["env"])
args = ["sandbox-exec", "-f", sys.argv[2], l["command"], *l["args"], *sys.argv[3:], *(l.get("trailingArgs") or [])]
p = subprocess.run(args, env=env, capture_output=True, text=True, timeout=600, cwd=os.environ.get("TOOL_CWD"))
out = p.stdout + p.stderr
print(out[-600:])
sys.exit(0 if "pong" in out.lower() else 1)
PY
  }
  mkdir -p "$WORK/project" && export TOOL_CWD="$WORK/project"
  PROMPT="Reply with the single word pong and nothing else. Use no tools."
  if command -v opencode > /dev/null; then check "opencode run" run_tool opencode run "$PROMPT"; else echo "  - opencode not installed"; fi
  if command -v codex > /dev/null; then check "codex exec" run_tool codex exec --skip-git-repo-check "$PROMPT"; else echo "  - codex not installed"; fi
  if command -v claude > /dev/null; then check "claude -p" run_tool claude -p "$PROMPT"; else echo "  - claude not installed"; fi
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "==> OK: Quail works offline"; else echo "==> $FAILED check(s) failed" >&2; exit 1; fi
