# ERPNext Local Dev Setup and Fixes (macOS)

This guide documents:
- How to set up ERPNext local development on a new system
- Fixes required for the hybrid setup used here (Docker for MariaDB/Redis, host for Bench/Frappe)

## 1. Architecture Used

- Host machine:
  - Python 3.11
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

brew install git python@3.11 node@18 yarn
python3.11 -m pip install --upgrade pip
python3.11 -m pip install --user frappe-bench
```

If `bench` is not found, add this to your shell profile:

```bash
export PATH="$HOME/Library/Python/3.11/bin:$PATH"
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
bench init frappe-bench --frappe-branch version-15 --python /opt/homebrew/bin/python3.11
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
bench get-app --branch version-15 erpnext
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
