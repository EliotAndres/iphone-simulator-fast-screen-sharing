#!/bin/bash
set -e

cd "$(dirname "$0")"

if ! command -v uv &>/dev/null; then
  echo "Error: uv is not installed. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

echo "Setting up Python environment for touch bridge..."
uv venv scripts/.venv --python 3.12
uv pip install --python scripts/.venv/bin/python grpclib fb-idb
echo ""
echo "Done. Run 'swift run' to start streaming."
