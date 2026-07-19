#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$ROOT_DIR/frappe-bench"

echo "[1/2] Stopping local Frappe processes (if running)..."
pkill -f "bench start|bench serve|socketio.js|bench watch|bench worker|bench schedule" >/dev/null 2>&1 || true

echo "[2/2] Stopping infrastructure containers..."
cd "$ROOT_DIR"
docker compose down

echo "Done. All local services are stopped."
