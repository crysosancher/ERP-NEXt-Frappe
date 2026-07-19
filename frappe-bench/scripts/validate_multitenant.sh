#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <tenant-site-a> <tenant-site-b>"
  echo "Example: $0 erp.local tenant2.erp.local"
  exit 1
fi

TENANT_A="$1"
TENANT_B="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SITES_DIR="${BENCH_ROOT}/sites"

DB_CONTAINER="${DB_CONTAINER:-erp-mariadb}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-root}"
WEB_PORT="${WEB_PORT:-8000}"

status_ok() {
  echo "[OK] $1"
}

status_fail() {
  echo "[FAIL] $1"
}

json_value() {
  local key="$1"
  local file="$2"

  sed -nE 's/^[[:space:]]*"'"${key}"'"[[:space:]]*:[[:space:]]*"?([^",}]+)"?[[:space:]]*,?[[:space:]]*$/\1/p' "$file" | head -n1
}

check_site_exists() {
  local site="$1"
  if [[ ! -f "${SITES_DIR}/${site}/site_config.json" ]]; then
    status_fail "Missing site config: sites/${site}/site_config.json"
    return 1
  fi
  status_ok "Found site config for ${site}"
}

check_docker() {
  if ! docker version >/dev/null 2>&1; then
    status_fail "Docker daemon is not reachable"
    return 1
  fi
  status_ok "Docker daemon is reachable"
}

check_db_container() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "${DB_CONTAINER}" 2>/dev/null || true)"
  if [[ "${running}" != "true" ]]; then
    status_fail "MariaDB container is not running: ${DB_CONTAINER}"
    return 1
  fi
  status_ok "MariaDB container is running: ${DB_CONTAINER}"
}

check_http_host_routing() {
  local site="$1"
  local code

  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: ${site}" "http://127.0.0.1:${WEB_PORT}/" || true)"
  if [[ "${code}" == "200" || "${code}" == "301" || "${code}" == "302" ]]; then
    status_ok "HTTP routing works for ${site} on port ${WEB_PORT} (status ${code})"
  else
    status_fail "HTTP routing failed for ${site} on port ${WEB_PORT} (status ${code:-none})"
    return 1
  fi
}

db_exists() {
  local db_name="$1"
  local exists

  exists="$(docker exec "${DB_CONTAINER}" mysql -N -s -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db_name}';" 2>/dev/null || true)"
  [[ "${exists}" == "${db_name}" ]]
}

table_count() {
  local db_name="$1"
  local table_name="$2"

  docker exec "${DB_CONTAINER}" mysql -N -s -u"${DB_ROOT_USER}" -p"${DB_ROOT_PASSWORD}" -e "SELECT COUNT(*) FROM \`${db_name}\`.\`${table_name}\`;" 2>/dev/null || echo "n/a"
}

echo "Validating multitenancy for: ${TENANT_A} and ${TENANT_B}"

check_docker
check_db_container

check_site_exists "${TENANT_A}"
check_site_exists "${TENANT_B}"

DB_A="$(json_value db_name "${SITES_DIR}/${TENANT_A}/site_config.json")"
DB_B="$(json_value db_name "${SITES_DIR}/${TENANT_B}/site_config.json")"

if [[ -z "${DB_A}" || -z "${DB_B}" ]]; then
  status_fail "Could not read db_name for one or more sites"
  exit 1
fi

echo "${TENANT_A} -> ${DB_A}"
echo "${TENANT_B} -> ${DB_B}"

if [[ "${DB_A}" == "${DB_B}" ]]; then
  status_fail "Both tenants point to the same database (${DB_A})"
  exit 1
fi
status_ok "Tenants map to different databases"

if db_exists "${DB_A}"; then
  status_ok "Database exists for ${TENANT_A}: ${DB_A}"
else
  status_fail "Database missing for ${TENANT_A}: ${DB_A}"
  exit 1
fi

if db_exists "${DB_B}"; then
  status_ok "Database exists for ${TENANT_B}: ${DB_B}"
else
  status_fail "Database missing for ${TENANT_B}: ${DB_B}"
  exit 1
fi

COUNT_A="$(table_count "${DB_A}" "tabCustomer")"
COUNT_B="$(table_count "${DB_B}" "tabCustomer")"

echo "${TENANT_A} tabCustomer count: ${COUNT_A}"
echo "${TENANT_B} tabCustomer count: ${COUNT_B}"

check_http_host_routing "${TENANT_A}"
check_http_host_routing "${TENANT_B}"

status_ok "Multitenant validation completed"