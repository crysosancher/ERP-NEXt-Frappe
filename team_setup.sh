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
  echo "Create/install bench environment first before running team setup."
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
: "${SAAS_DB_HOST:=162.19.221.228}"
: "${SAAS_DB_PORT:=3308}"
: "${SAAS_DB_ROOT_USER:=root}"
: "${SAAS_DB_ROOT_PASSWORD:=admin}"
: "${SAAS_DB_CONTAINER:=erp-mariadb}"
: "${SAAS_ERP_APP:=erpnext}"
: "${SAAS_BASE_DOMAIN:=erp.local}"
: "${SAAS_REDIRECT_MODE:=nip_io}"

cd "$BENCH_DIR"

echo "[1/3] Applying shared bench/global configuration..."
"$BENCH_CMD" set-config -g redis_cache redis://127.0.0.1:13000
"$BENCH_CMD" set-config -g redis_queue redis://127.0.0.1:11000
"$BENCH_CMD" set-config -g redis_socketio redis://127.0.0.1:12000
"$BENCH_CMD" set-config -g dns_multitenant true
"$BENCH_CMD" set-config -g serve_default_site false
"$BENCH_CMD" set-config -g default_site "$SITE_NAME"

echo "[2/3] Applying SaaS provisioning configuration..."
"$BENCH_CMD" set-config -g saas_db_host "$SAAS_DB_HOST"
"$BENCH_CMD" set-config -g saas_db_port "$SAAS_DB_PORT"
"$BENCH_CMD" set-config -g saas_db_root_user "$SAAS_DB_ROOT_USER"
"$BENCH_CMD" set-config -g saas_db_root_password "$SAAS_DB_ROOT_PASSWORD"
"$BENCH_CMD" set-config -g saas_db_container "$SAAS_DB_CONTAINER"
"$BENCH_CMD" set-config -g saas_erp_app "$SAAS_ERP_APP"
"$BENCH_CMD" set-config -g saas_base_domain "$SAAS_BASE_DOMAIN"
"$BENCH_CMD" set-config -g saas_redirect_mode "$SAAS_REDIRECT_MODE"

echo "[3/3] Ensuring dev alias for the central site..."
SITE_PREFIX="${SITE_NAME%%.*}"
ALIAS_HOST="${SITE_PREFIX}.127.0.0.1.nip.io"
if [[ -d "sites/$SITE_NAME" && ! -e "sites/$ALIAS_HOST" ]]; then
  ln -s "$SITE_NAME" "sites/$ALIAS_HOST"
  echo "[INFO] Created alias: $ALIAS_HOST -> $SITE_NAME"
else
  echo "[INFO] Alias already exists or site not created yet"
fi

echo "Done. Team setup applied."
echo "Start app with: ./start_all.sh web $SITE_NAME"
