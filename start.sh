#!/bin/bash
set -e

cd "$(dirname "$0")"

tunnel=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel|-t) tunnel=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--tunnel]

Starts the Swift streamer (which also serves the browser page and
WebSocket on port 3738). Ctrl-C stops it.

  --tunnel, -t   Also expose the running port via cloudflared.
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# ─── Preflight ───────────────────────────────────────────────────────────────
if [[ ! -x scripts/.venv/bin/python ]]; then
  echo "[start] Python venv missing. Run ./install.sh first."
  exit 1
fi

PORT=3738
if lsof -i :$PORT -P -n >/dev/null 2>&1; then
  echo "[start] Port $PORT is busy. Free it first:"
  lsof -i :$PORT -P -n
  exit 1
fi

if [[ $tunnel -eq 1 ]] && ! command -v cloudflared >/dev/null 2>&1; then
  echo "[start] cloudflared not found. Install with: brew install cloudflared"
  exit 1
fi

# ─── Run ─────────────────────────────────────────────────────────────────────
# Optional: SIMULATOR_STREAM_PREFER_SOFTWARE_ENCODER=1 — prefer software H.264 in VMs where HW VT fails.
# Inherited by `swift run` (see README).

pids=()
cleanup() {
  echo
  echo "[start] Stopping…"
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

echo "[start] Swift streamer on http://localhost:$PORT"
PORT=$PORT swift run SimulatorStream &
pids+=($!)

if [[ $tunnel -eq 1 ]]; then
  echo "[start] Cloudflare tunnel → http://localhost:$PORT"
  cloudflared tunnel --url "http://localhost:$PORT" &
  pids+=($!)
fi

echo "[start] Running (pids: ${pids[*]}). Ctrl-C to stop."
wait
