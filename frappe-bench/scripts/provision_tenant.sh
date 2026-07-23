#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <site-domain> [admin-password] [db-root-password]"
  echo "Example: $0 tenant1.erp.local admin root"
  exit 1
fi

SITE_DOMAIN="$1"
ADMIN_PASSWORD="${2:-admin}"
DB_ROOT_PASSWORD="${3:-root}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3307}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
ERP_APP="${ERP_APP:-erpnext}"
DB_CONTAINER="${DB_CONTAINER:-erp-mariadb}"
SKIP_DB_GRANT="${SKIP_DB_GRANT:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Helpers ───────────────────────────────────────────────────────────────────
json_value() {
  local key="$1"
  local file="$2"
  sed -nE 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*"?([^",}]+)"?[[:space:]]*,?[[:space:]]*$/\1/p' "$file" | head -n1
}

# Load remote DB config from common_site_config.json if present
saas_db_host="$(json_value saas_db_host "${BENCH_ROOT}/sites/common_site_config.json")"
saas_db_port="$(json_value saas_db_port "${BENCH_ROOT}/sites/common_site_config.json")"

# ─── Progress Ring ────────────────────────────────────────────────────────────
SPINNER_PID=""
SPINNER_DONE=0

spinner_start() {
  local msg="$1"
  SPINNER_DONE=0
  (
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while [[ $SPINNER_DONE -eq 0 ]]; do
      printf "\r  \033[36m[%s]\033[0m %s" "${chars:i%10:1}" "$msg"
      sleep 0.1
    done
    printf "\r  \033[32m[✓]\033[0m %s\n" "$msg"
  ) &
  SPINNER_PID=$!
}

spinner_done() {
  SPINNER_DONE=1
  sleep 0.2
  wait $SPINNER_PID 2>/dev/null || true
  SPINNER_PID=""
}

# Cleanup spinner on unexpected exit
trap 'spinner_done 2>/dev/null; exit 1' INT TERM

if [[ ! -f "${BENCH_ROOT}/Procfile" ]]; then
  echo "Error: bench root not found at ${BENCH_ROOT}"
  exit 1
fi

cd "${BENCH_ROOT}"

if [[ -d "sites/${SITE_DOMAIN}" ]]; then
  echo "Error: site already exists: ${SITE_DOMAIN}"
  exit 1
fi

log_cmd() {
  # Run a command with output silenced; returns its exit code.
  # Output goes to a shared log file; errors are surfaced only on failure.
  local log="$1"; shift
  "$@" > "$log" 2>&1
  return $?
}

run_step() {
  # spinner_start <label>; <cmd>; spinner_done [label]
  local label="$1"; shift
  local log="/tmp/bench_provision_$$.log"
  spinner_start "$label"
  if log_cmd "$log" "$@"; then
    spinner_done
  else
    spinner_done
    echo ""
    echo "  \033[31m✗\033[0m FAILED: $label"
    echo "  ── Output log ──────────────────────────────────────────"
    sed 's/^/  /' "$log"
    echo "  ─────────────────────────────────────────────────────────"
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

echo ""
echo "▸ Creating site: ${SITE_DOMAIN}"
run_step "Running database setup & migrations" \
  bench new-site "${SITE_DOMAIN}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-root-username "${DB_ROOT_USER}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}"

# bench new-site writes db_host/db_port to site_config.json based on what
# it actually connected to (remote). But ensure it matches the remote settings
# so install-app connects to the right DB.
SITE_CONFIG_FILE="${BENCH_ROOT}/sites/${SITE_DOMAIN}/site_config.json"
if [[ -f "${SITE_CONFIG_FILE}" ]]; then
  _tmp=$(mktemp)
  sed -E "s/(\"db_host\":[[:space:]]*)\"[^\"]*\"/\1\"${saas_db_host:-${DB_HOST}}\"/" \
      "${SITE_CONFIG_FILE}" > "${_tmp}"
  sed -E "s/(\"db_port\":[[:space:]]*)[0-9]+/\1${saas_db_port:-${DB_PORT}}/" \
      "${_tmp}" > "${SITE_CONFIG_FILE}"
  rm -f "${_tmp}"
fi

echo "▸ Installing ${ERP_APP}"
run_step "Installing apps & running post-install hooks" \
  bench --site "${SITE_DOMAIN}" install-app "${ERP_APP}"

echo "▸ Configuring host"
run_step "Setting host_name and DB grants" \
  bench --site "${SITE_DOMAIN}" set-config host_name "https://${SITE_DOMAIN}"

if [[ "${SKIP_DB_GRANT}" != "true" ]]; then
  SITE_CONFIG_FILE="${BENCH_ROOT}/sites/${SITE_DOMAIN}/site_config.json"
  DB_NAME="$(json_value db_name "${SITE_CONFIG_FILE}")"
  SITE_DB_PASSWORD="$(json_value db_password "${SITE_CONFIG_FILE}")"

  if [[ -n "${DB_NAME}" && -n "${SITE_DB_PASSWORD}" ]]; then
    spinner_start "Granting DB access for ${DB_NAME}"
    # DB is remote (162.19.221.228:3308) — use mysql CLI directly, not Docker
    _DB_HOST="${saas_db_host:-${DB_HOST}}"
    _DB_PORT="${saas_db_port:-${DB_PORT}}"
    if command -v mysql &>/dev/null; then
      mysql -h"${_DB_HOST}" -P"${_DB_PORT}" -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e \
        "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'%' IDENTIFIED BY '${SITE_DB_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null || true
    fi
    spinner_done
  fi
fi

echo ""
echo "  \033[32m✓\033[0m Tenant provisioned: \033[1m${SITE_DOMAIN}\033[0m"
echo "  Next: add DNS/hosts entry and route this host to bench web port 8000."
