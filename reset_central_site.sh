#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$ROOT_DIR/frappe-bench"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/.env.example"
BENCH_CMD="$BENCH_DIR/env/bin/bench"

if [[ ! -d "$BENCH_DIR" ]]; then
  echo "[ERROR] Bench directory not found at: $BENCH_DIR"
  exit 1
fi

if [[ ! -x "$BENCH_CMD" ]]; then
  echo "[ERROR] Bench CLI not found at: $BENCH_CMD"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "[INFO] Created .env from .env.example"
  else
    echo "[ERROR] Missing .env and .env.example"
    exit 1
  fi
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${SITE_NAME:=crysomedia.erp.local}"
: "${SITE_ADMIN_PASSWORD:=admin}"
: "${LOCAL_DB_HOST:=127.0.0.1}"
: "${LOCAL_DB_PORT:=3307}"
: "${LOCAL_DB_ROOT_USER:=root}"
: "${LOCAL_DB_ROOT_PASSWORD:=root}"
: "${MARIADB_USER_HOST_LOGIN_SCOPE:=%}"

SITE_PREFIX="${SITE_NAME%%.*}"
ALIAS_HOST="${SITE_PREFIX}.127.0.0.1.nip.io"
SITE_DIR="$BENCH_DIR/sites/$SITE_NAME"
SITE_CONFIG="$SITE_DIR/site_config.json"

if ! command -v mysql >/dev/null 2>&1; then
  echo "[ERROR] mysql client is required but was not found in PATH"
  exit 1
fi

echo "[1/6] Starting infra containers..."
cd "$ROOT_DIR"
docker compose up -d

echo "[2/6] Dropping current site DB/user (if site exists)..."
if [[ -f "$SITE_CONFIG" ]]; then
  DB_NAME="$(sed -n 's/.*"db_name": "\([^"]*\)".*/\1/p' "$SITE_CONFIG")"
  if [[ -n "$DB_NAME" ]]; then
    mysql -h "$LOCAL_DB_HOST" -P "$LOCAL_DB_PORT" -u "$LOCAL_DB_ROOT_USER" -p"$LOCAL_DB_ROOT_PASSWORD" \
      -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; DROP USER IF EXISTS \"$DB_NAME\"@\"%\"; DROP USER IF EXISTS \"$DB_NAME\"@\"172.21.0.1\"; FLUSH PRIVILEGES;"
  fi
fi

echo "[3/6] Removing old site folder + alias..."
rm -rf "$SITE_DIR"
rm -f "$BENCH_DIR/sites/$ALIAS_HOST"

echo "[4/6] Creating site non-interactively..."
cd "$BENCH_DIR"
"$BENCH_CMD" new-site "$SITE_NAME" \
  --db-host "$LOCAL_DB_HOST" \
  --db-port "$LOCAL_DB_PORT" \
  --db-root-username "$LOCAL_DB_ROOT_USER" \
  --db-root-password "$LOCAL_DB_ROOT_PASSWORD" \
  --admin-password "$SITE_ADMIN_PASSWORD" \
  --mariadb-user-host-login-scope "$MARIADB_USER_HOST_LOGIN_SCOPE"

echo "[5/6] Installing apps and migrating..."
if [[ -d "$BENCH_DIR/apps/erpnext" ]]; then
  "$BENCH_CMD" --site "$SITE_NAME" install-app erpnext
fi
if [[ -d "$BENCH_DIR/apps/saas_control" ]]; then
  "$BENCH_CMD" --site "$SITE_NAME" install-app saas_control
fi
"$BENCH_CMD" --site "$SITE_NAME" migrate

echo "[6/6] Re-applying global setup + alias..."
cd "$ROOT_DIR"
./team_setup.sh

echo "Done. Central site reset completed for $SITE_NAME"
echo "Run: ./start_all.sh web $SITE_NAME"
