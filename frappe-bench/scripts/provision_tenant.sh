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

if [[ ! -f "${BENCH_ROOT}/Procfile" ]]; then
  echo "Error: bench root not found at ${BENCH_ROOT}"
  exit 1
fi

cd "${BENCH_ROOT}"

if [[ -d "sites/${SITE_DOMAIN}" ]]; then
  echo "Error: site already exists: ${SITE_DOMAIN}"
  exit 1
fi

json_value() {
  local key="$1"
  local file="$2"
  sed -nE 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*"?([^",}]+)"?[[:space:]]*,?[[:space:]]*$/\1/p' "$file" | head -n1
}

echo "Creating tenant site: ${SITE_DOMAIN}"
bench new-site "${SITE_DOMAIN}" \
  --db-host "${DB_HOST}" \
  --db-port "${DB_PORT}" \
  --db-root-username "${DB_ROOT_USER}" \
  --db-root-password "${DB_ROOT_PASSWORD}" \
  --admin-password "${ADMIN_PASSWORD}"

echo "Installing ${ERP_APP} on ${SITE_DOMAIN}"
bench --site "${SITE_DOMAIN}" install-app "${ERP_APP}"

echo "Setting host_name for ${SITE_DOMAIN}"
bench --site "${SITE_DOMAIN}" set-config host_name "https://${SITE_DOMAIN}"

if [[ "${SKIP_DB_GRANT}" != "true" ]]; then
  SITE_CONFIG_FILE="${BENCH_ROOT}/sites/${SITE_DOMAIN}/site_config.json"
  DB_NAME="$(json_value db_name "${SITE_CONFIG_FILE}")"
  SITE_DB_PASSWORD="$(json_value db_password "${SITE_CONFIG_FILE}")"

  if [[ -n "${DB_NAME}" && -n "${SITE_DB_PASSWORD}" ]] && docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
    echo "Ensuring DB grants for ${DB_NAME}@% in ${DB_CONTAINER}"
    docker exec "${DB_CONTAINER}" mysql -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e \
      "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_NAME}'@'%' IDENTIFIED BY '${SITE_DB_PASSWORD}'; FLUSH PRIVILEGES;"
  else
    echo "Skipping DB grant update (missing DB metadata or container not found)"
  fi
fi

echo "Tenant provisioned successfully: ${SITE_DOMAIN}"
echo "Next: add DNS/hosts entry and route this host to bench web port 8000."
