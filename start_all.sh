#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$ROOT_DIR/frappe-bench"
SITES_DIR="$BENCH_DIR/sites"

MODE="${1:-web}"                # web | full
SITE_NAME="${2:-crysomedia.erp.local}"
SITE_PREFIX="${SITE_NAME%%.*}"
ALIAS_HOST="${SITE_PREFIX}.127.0.0.1.nip.io"

if [[ ! -d "$BENCH_DIR" ]]; then
  echo "[ERROR] Bench directory not found at: $BENCH_DIR"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/docker-compose.yml" ]]; then
  echo "[ERROR] docker-compose.yml not found at: $ROOT_DIR/docker-compose.yml"
  exit 1
fi

echo "[1/3] Starting infrastructure containers (MariaDB + Redis)..."
cd "$ROOT_DIR"
docker compose up -d

if [[ -d "$SITES_DIR/$SITE_NAME" ]]; then
  if [[ ! -e "$SITES_DIR/$ALIAS_HOST" ]]; then
    echo "[2/3] Creating site alias: $ALIAS_HOST -> $SITE_NAME"
    ln -s "$SITE_NAME" "$SITES_DIR/$ALIAS_HOST"
  else
    echo "[2/3] Site alias already exists: $ALIAS_HOST"
  fi
else
  echo "[2/3] Site folder not found for $SITE_NAME. Skipping alias creation."
fi

echo "[3/3] Starting Frappe app..."
cd "$BENCH_DIR"

if [[ "$MODE" == "web" ]]; then
  echo "Serving web on:"
  echo "  - http://localhost:8000"
  echo "  - http://$ALIAS_HOST:8000"
  exec bench serve --port 8000
elif [[ "$MODE" == "full" ]]; then
  echo "Starting full dev stack with bench start"
  exec bench start
else
  echo "[ERROR] Invalid mode: $MODE"
  echo "Usage: ./start_all.sh [web|full] [site-name]"
  exit 1
fi
