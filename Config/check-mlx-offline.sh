#!/bin/bash
# Proves quail-server's MLX path makes no network connection (ADR D-044): the tokenizer package
# (swift-transformers) drags in a Hugging Face client, crypto and HTTP code that Quail never uses.
# Runs the server under sandbox-exec with outbound IP connections denied *and fatal*, loads an MLX
# model and generates. If anything tried to connect, the server is killed and this fails.
#
#   task check:mlx-offline                       (a Debug build in ./DerivedData, the store's mlx folder)
#   QUAIL_SERVER=… MLX_DIR=… MODEL=… Config/check-mlx-offline.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${QUAIL_SERVER:-$(find "$ROOT/DerivedData/Build/Products" -path '*/Quail.app/Contents/MacOS/quail-server' -print -quit)}"
MLX_DIR="${MLX_DIR:-$HOME/Library/Application Support/Quail/Models/mlx}"
MODEL="${MODEL:-$(ls "$MLX_DIR" | head -1)}"
PORT="${PORT:-18979}"
[ -x "$SERVER" ] || { echo "error: no quail-server found; run task build (or set QUAIL_SERVER)" >&2; exit 1; }
[ -n "$MODEL" ] || { echo "error: no MLX model in $MLX_DIR (set MLX_DIR and MODEL)" >&2; exit 1; }

PROFILE="$(mktemp -t quail-offline).sb"
cat > "$PROFILE" <<'SB'
(version 1)
(allow default)
(deny network-outbound (remote ip) (with send-signal SIGKILL))
SB
LOG="$(mktemp -t quail-offline-log)"
trap 'kill "$PID" 2>/dev/null || true; rm -f "$PROFILE" "$LOG"' EXIT

echo "==> control: the profile really blocks a connection"
if (sandbox-exec -f "$PROFILE" /usr/bin/curl -sS -m 5 -o /dev/null https://huggingface.co) > /dev/null 2>&1; then
  echo "error: the sandbox profile let a connection out; this check proves nothing" >&2
  exit 1
fi
echo "    blocked, as it should be"

echo "==> starting $SERVER offline, model $MODEL"
sandbox-exec -f "$PROFILE" "$SERVER" --port "$PORT" --mlx-dir "$MLX_DIR" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -sf "localhost:$PORT/health" > /dev/null && break; sleep 0.2; done
REPLY="$(curl -s -m 300 "localhost:$PORT/v1/chat/completions" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"temperature\":0,\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"/no_think Reply with the single word pong\"}]}")"
if echo "$REPLY" | grep -qi pong && kill -0 "$PID" 2>/dev/null; then
  echo "==> OK: loaded $MODEL and generated with every outbound connection fatal; none was attempted"
else
  echo "error: the server didn't answer, or was killed for trying to connect" >&2
  echo "$REPLY" | head -c 400 >&2; echo >&2; tail -5 "$LOG" >&2
  exit 1
fi
