# ERPNext Local Dev Setup and Fixes (macOS)

This guide documents:
- How to set up ERPNext local development on a new system
- Fixes required for the hybrid setup used here (Docker for MariaDB/Redis, host for Bench/Frappe)

## 0. Fresh Clone Quick Start (Team)

From a fresh clone, the fastest path is:

```bash
cd /Users/<you>/.../ERP-NEXT
chmod +x team_setup.sh start_all.sh stop_all.sh
./team_setup.sh
./start_all.sh web
```

If you ever get stuck with interactive site/database prompts, run the non-interactive reset (uses values from `.env`):

```bash
chmod +x reset_central_site.sh
./reset_central_site.sh
```

Open:

- `http://localhost:8000/saas`
- `http://crysomedia.127.0.0.1.nip.io:8000/saas`

Stop everything:

```bash
./stop_all.sh
```

Notes:

- `team_setup.sh` auto-creates `.env` from `.env.example` if missing.
- Edit `.env` only when you need different DB/domain values.

## 1. Architecture Used

- Host machine:
  - Python 3.14
  - Node.js 18
  - Yarn
  - Bench CLI
  - Frappe/ERPNext code and processes
- Docker containers:
  - MariaDB 10.6
  - Redis (cache, queue, socketio)

## 2. Prerequisites on New System

Install these on macOS host:

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install git python@3.14 node@18 yarn
python3.14 -m pip install --upgrade pip
python3.14 -m pip install --user frappe-bench
```

If `bench` is not found, add this to your shell profile:

```bash
export PATH="$HOME/Library/Python/3.14/bin:$PATH"
```

Then reload shell.

## 3. Docker Compose (Infra)

Create `docker-compose.yml` in project root:

```yaml
services:
  mariadb:
    image: mariadb:10.6
    container_name: erp-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
    ports:
      - "3307:3306"
    volumes:
      - mariadb_data:/var/lib/mysql

  redis-cache:
    image: redis:7-alpine
    container_name: erp-redis-cache
    restart: unless-stopped
    ports:
      - "13000:6379"

  redis-queue:
    image: redis:7-alpine
    container_name: erp-redis-queue
    restart: unless-stopped
    ports:
      - "11000:6379"

  redis-socketio:
    image: redis:7-alpine
    container_name: erp-redis-socketio
    restart: unless-stopped
    ports:
      - "12000:6379"

volumes:
  mariadb_data:
```

Start infra:

```bash
docker compose up -d
docker compose ps
```

## 4. Bench + Site Setup

```bash
bench init frappe-bench --frappe-branch version-16 --python /opt/homebrew/bin/python3.14
cd frappe-bench
```

Create site (using Docker MariaDB on port 3307):

```bash
bench new-site erp.local \
  --db-host 127.0.0.1 \
  --db-port 3307 \
  --db-root-username root \
  --db-root-password root \
  --admin-password admin
```

Configure Redis endpoints:

```bash
bench set-config -g redis_cache redis://127.0.0.1:13000
bench set-config -g redis_queue redis://127.0.0.1:11000
bench set-config -g redis_socketio redis://127.0.0.1:12000
```

Install ERPNext and enable dev mode:

```bash
bench get-app --branch version-16 erpnext
bench --site erp.local install-app erpnext
bench --site erp.local set-config developer_mode 1
bench --site erp.local clear-cache
```

## 5. Required Fixes for This Hybrid Setup

### Fix A: Disable host-based routing so localhost works

Symptom:
- `127.0.0.1:8000` returns `404 ... does not exist`

Fix:

```bash
bench set-config -g dns_multitenant false
```

Expected behavior after fix:
- `http://127.0.0.1:8000` loads login page

### Fix B: Avoid Redis port conflicts (Bench vs Docker Redis)

Symptom:
- `bench start` fails with `bind: Address already in use` for Redis ports

Fix:
- Edit `frappe-bench/Procfile` and remove local Redis entries:

Remove these lines:

```text
redis_cache: redis-server config/redis_cache.conf
redis_queue: redis-server config/redis_queue.conf
```

Keep web/scheduler/worker/watch/socketio process lines.

### Fix C: SocketIO command compatibility

Symptom:
- `bench start` fails with `No such command 'socketio'`

Fix:
- In `frappe-bench/Procfile`, set socketio to Node script directly:

```text
socketio: /Users/<your_user>/.nvm/versions/node/v18.x.x/bin/node apps/frappe/socketio.js
```

Important:
- Update the Node path to match your system.

### Fix D: MySQL SSL mismatch from client defaults

Symptom:
- Site creation fails with TLS/SSL error during DB restore

Fix:
- Add `skip-ssl` under `[client]` in `~/.my.cnf`:

```ini
[client]
user=root
host=127.0.0.1
port=3307
skip-ssl
```

## 6. Daily Start and Stop

From project root:

```bash
docker compose up -d
```

From `frappe-bench`:

```bash
source ~/.nvm/nvm.sh
nvm use 18
bench start
```

Open:
- http://127.0.0.1:8000

Login:
- User: Administrator
- Password: admin

Stop:
- In bench terminal: `Ctrl + C`
- Infra: `docker compose down`

### One-command start/stop (recommended)

From project root:

```bash
cd /Users/crysosancher/Documents/Cryso/Thoughtins/ERP-NEXT
./start_all.sh web
```

For full dev stack (watch, workers, scheduler, socketio):

```bash
./start_all.sh full
```

Stop everything:

```bash
./stop_all.sh
```

Default working URLs after startup:

- `http://localhost:8000/login`
- `http://crysomedia.127.0.0.1.nip.io:8000/login`

SaaS onboarding page:

- `http://localhost:8000/saas`
- `http://crysomedia.127.0.0.1.nip.io:8000/saas`

## 7. Quick Troubleshooting

### App not opening

```bash
curl -I http://127.0.0.1:8000/
```

- `200` means app is up
- `404` usually means routing issue (apply Fix A)

### Bench process conflict

```bash
pkill -f "bench start|bench serve|socketio.js|bench watch|bench worker|bench schedule" || true
```

Then restart bench.

### Docker service check

```bash
docker compose ps
```

All containers should be `Up`.

## 8. Notes

- Node 18 is recommended for ERPNext/Frappe v15 asset pipeline.
- `wkhtmltopdf` may be needed later for PDF generation, but core dev setup works without it.
- Change default passwords before using beyond local development.

## 9. Multi-Tenant SaaS Setup (Implemented)

This workspace is now configured for host-based multi-tenancy:

- `frappe-bench/sites/common_site_config.json` has:
  - `dns_multitenant: true`
  - `serve_default_site: false`

### 9.1 Local domain routing for tenants

For local testing, map tenant domains in `/etc/hosts`:

```text
127.0.0.1 tenant1.erp.local
127.0.0.1 tenant2.erp.local
```

Then access tenants via:

- `http://tenant1.erp.local:8000`
- `http://tenant2.erp.local:8000`

No-hosts-file alternative (works without sudo edits):

- `http://tenant1.127.0.0.1.nip.io:8000`
- `http://tenant2.127.0.0.1.nip.io:8000`

### 9.2 Create a new tenant (automated)

Use the provisioning script:

```bash
cd frappe-bench
chmod +x scripts/provision_tenant.sh
./scripts/provision_tenant.sh tenant1.erp.local admin root
```

Arguments:

1. site-domain (required)
2. admin-password (optional, default: `admin`)
3. db-root-password (optional, default: `root`)

Optional env vars:

- `DB_HOST` (default: `127.0.0.1`)
- `DB_PORT` (default: `3307`)
- `DB_ROOT_USER` (default: `root`)
- `ERP_APP` (default: `erpnext`)
- `DB_CONTAINER` (default: `erp-mariadb`)
- `SKIP_DB_GRANT` (default: `false`)

The provisioning script also ensures DB grants for `site_db_user@'%'` in MariaDB by default, which avoids host-bridge auth issues in Docker-based local setups.

### 9.3 Production SaaS checklist

1. Use wildcard DNS: `*.yourdomain.com` -> load balancer/IP.
2. Use wildcard TLS cert for `*.yourdomain.com`.
3. Put Frappe behind Nginx/Traefik/Caddy and preserve the host header.
4. Keep one ERPNext site/database per tenant.
5. Add scheduled per-tenant backups and restore testing.

### 9.4 Validate multi-tenant setup (automated)

Run the validation script after creating at least two tenant sites:

```bash
cd frappe-bench
chmod +x scripts/validate_multitenant.sh
./scripts/validate_multitenant.sh erp.local tenant2.erp.local
```

What it validates:

1. Docker daemon is reachable.
2. MariaDB container is running.
3. Both site configs exist in `sites/<tenant>/site_config.json`.
4. Each site maps to a different `db_name`.
5. Both mapped databases exist in MariaDB.
6. HTTP host-based routing works for both tenants on port `8000`.

## 10. SaaS Onboarding API (Implemented)

The custom app `saas_control` is installed on `erp.local` and provides two guest APIs:

1. `saas_control.saas_control.api.create_or_login`
2. `saas_control.saas_control.api.resolve_tenant`

### 10.1 New user signup -> create new tenant site

POST endpoint:

```text
/api/method/saas_control.saas_control.api.create_or_login
```

Sample payload:

```json
{
  "email": "owner1@example.com",
  "full_name": "Owner One",
  "company_slug": "tenant3",
  "password": "StrongPass@123"
}
```

Behavior:

1. Checks tenant registry by email.
2. If not found, provisions `tenant3.erp.local` synchronously using `scripts/provision_tenant.sh`.
3. Saves mapping in registry table.
4. Returns tenant login redirect URL.

### 10.2 Existing user -> redirect to tenant login

If the same email already exists in registry, `create_or_login` skips provisioning and returns existing tenant login redirect.

You can also resolve directly:

```text
/api/method/saas_control.saas_control.api.resolve_tenant
```

Sample payload:

```json
{
  "email": "owner1@example.com"
}
```

### 10.3 Config knobs (optional)

Set these in `sites/common_site_config.json` if needed:

- `saas_base_domain` (default: `erp.local`)
- `saas_db_host` (default: `127.0.0.1`)
- `saas_db_port` (default: `3307`)
- `saas_db_root_user` (default: `root`)
- `saas_db_root_password` (default: `root`)
- `saas_db_container` (default: `erp-mariadb`)
- `saas_erp_app` (default: `erpnext`)

## 11. SaaS Quick Start (Dev Team)

This section is the fastest way for any teammate to clone and run the SaaS onboarding flow.

### 11.1 One-time setup after clone

From repo root:

```bash
chmod +x team_setup.sh start_all.sh stop_all.sh
./team_setup.sh
```

What this does:

1. Creates `.env` from `.env.example` (if missing).
2. Applies shared bench config for multitenancy.
3. Applies SaaS DB provisioning config.
4. Creates local `nip.io` alias for the central site.

### 11.2 Start the app

From repo root:

```bash
./start_all.sh web
```

Open SaaS page:

- `http://localhost:8000/saas`
- `http://crysomedia.127.0.0.1.nip.io:8000/saas`

### 11.3 Create tenant via UI

1. Enter email and click **Continue**.
2. If user is new, fill Full Name, Company Slug, Password.
3. Click **Create Tenant**.
4. Wait for provisioning to complete (loader is shown during creation).
5. You will be redirected to tenant login URL automatically.

### 11.4 Stop everything

```bash
./stop_all.sh
```

### 11.5 Common issues

1. **ERR_NAME_NOT_RESOLVED on `*.erp.local`**
  Use the `nip.io` URL returned by the API/UI (`*.127.0.0.1.nip.io`) for local runs.
2. **Port 8000 not reachable**
  Start again with `./start_all.sh web`.
3. **Docker services not up**
  Run `docker compose ps` and ensure MariaDB + Redis are `Up`.
