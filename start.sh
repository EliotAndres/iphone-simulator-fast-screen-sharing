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
WebSocket on a single port). Ctrl-C stops it.

Tries ports 3738..3742 in order and uses the first free one.

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

PORT=""
for p in 3738 3739 3740 3741 3742; do
  if ! lsof -i :$p -P -n >/dev/null 2>&1; then
    PORT=$p
    break
  fi
done
if [[ -z "$PORT" ]]; then
  echo "[start] All candidate ports busy (3738-3742). Free one and retry:"
  lsof -i :3738 -i :3739 -i :3740 -i :3741 -i :3742 -P -n | head
  exit 1
fi
echo "[start] Using port $PORT"

if [[ $tunnel -eq 1 ]] && ! command -v cloudflared >/dev/null 2>&1; then
  echo "[start] cloudflared not found. Install with: brew install cloudflared"
  exit 1
fi

# ─── Run ─────────────────────────────────────────────────────────────────────
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
