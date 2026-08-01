# Hardened Moodle Container Stack

A highly secure, future-proof Moodle LMS deployment that is:

- **Host-mounted code & data** — Moodle source and `moodledata` live in local directories on the host (not only inside the container).
- **External networks** — joins your existing **Nginx Proxy Manager** network and **PostgreSQL** network.
- **Updateable via GitHub + CLI** — first boot clones Moodle into the host path; later updates via git on the host or `./scripts/update-moodle.sh`.
- **Hardened** — non-root user, capability dropping, Redis sessions, no published ports by default.
- **Production-ready** — Valkey + Ofelia cron + automatic install.

> **Note on `systemctl`:** Full systemd inside a container requires privileged mode and weakens security. Cron is provided by the **Ofelia** sidecar.

| Component | Choice |
|-----------|--------|
| Web server | **Apache** (PHP 8.3 Bookworm) |
| Database | **External PostgreSQL** (your container) |
| Proxy | **External Nginx Proxy Manager** |
| Cron | **Ofelia** |
| Cache | Valkey (internal) |

---

## Prerequisites

```bash
# External networks (names must match .env)
docker network create nginx-proxy-manager   # or your NPM network name
docker network create postgres-net          # or your Postgres network name

# Host directories for code + data (UID 1000 = moodle user in container)
mkdir -p ./moodle ./moodledata
sudo chown -R 1000:1000 ./moodle ./moodledata
```

Your PostgreSQL container must already be on `DB_NETWORK` and reachable as `DB_HOST`.

---

## Quick Start

```bash
git clone https://github.com/YOUR_ORG/moodle-hardened.git
cd moodle-hardened

cp .env.example .env
nano .env
# Set at least:
#   WWWROOT, ADMIN_PASS, DB_HOST, DB_PASSWORD
#   PROXY_NETWORK, DB_NETWORK
#   MOODLE_CODE_PATH, MOODLEDATA_PATH (defaults: ./moodle, ./moodledata)

docker compose up -d --build
docker compose logs -f moodle
```

On first start, if `./moodle` is empty, the entrypoint clones `MOODLE_BRANCH` from GitHub into that host directory, writes `config.php`, and runs the CLI installer.

Point Nginx Proxy Manager at container `moodle_app` port `80` on the shared proxy network.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host                                                       │
│   ./moodle      ──bind──► /var/www/html  (moodle_app)       │
│   ./moodledata  ──bind──► /var/moodledata                   │
└─────────────────────────────────────────────────────────────┘

Networks:
  PROXY_NETWORK (external)  ← moodle_app  ↔  Nginx Proxy Manager
  DB_NETWORK    (external)  ← moodle_app  ↔  PostgreSQL
  moodle_internal           ← moodle_app, moodle_cache, moodle_ofelia
```

| Service   | Image                         | Networks              | Role                |
|-----------|-------------------------------|-----------------------|---------------------|
| `moodle`  | custom PHP 8.3 + Apache       | proxy, database, internal | App                 |
| `cache`   | valkey:8-alpine               | internal              | Sessions / cache    |
| `ofelia`  | mcuadros/ofelia               | internal              | Cron                |

No internal Postgres service and no published host ports by default.

---

## Environment highlights

| Variable | Purpose | Example |
|----------|---------|---------|
| `MOODLE_CODE_PATH` | Host path for Moodle code | `./moodle` |
| `MOODLEDATA_PATH` | Host path for moodledata | `./moodledata` |
| `PROXY_NETWORK` | External NPM network name | `nginx-proxy-manager` |
| `DB_NETWORK` | External Postgres network name | `postgres-net` |
| `DB_HOST` | Postgres service/container name on that network | `postgres` |
| `WWWROOT` | Public HTTPS URL | `https://moodle.example.com` |
| `REVERSE_PROXY` / `SSL_PROXY` | Behind NPM | `true` |

---

## Updating Moodle code (on the host)

Because code lives on the host:

```bash
cd ./moodle
git fetch --tags
git checkout MOODLE_502_STABLE   # or a tag
# or: git pull

docker compose exec moodle php admin/cli/upgrade.php --non-interactive
docker compose exec moodle php admin/cli/purge_caches.php
```

Or use `./scripts/update-moodle.sh` after adjusting it for host-mounted trees.

---

## Cron (Ofelia)

```ini
[job-exec "moodle-cron"]
schedule = @every 1m
container = moodle_app
command = php /var/www/html/admin/cli/cron.php
user = moodle
no-overlap = true
```

---

## Security notes

- `cap_drop: ALL` + minimal capabilities
- `no-new-privileges:true`
- No host port binding when behind NPM
- `moodledata` outside the web root (separate bind mount)
- `config.php` mode `440` on first generate
- Block `vendor/`, `node_modules/`, `.git/`, etc. via Apache rules or NPM (see security-check paths)

---

## Useful commands

```bash
docker compose logs -f moodle ofelia
docker compose exec moodle bash
docker compose exec moodle php admin/cli/cron.php

# Confirm networks
docker network inspect nginx-proxy-manager
docker network inspect postgres-net
```

---

## License

This repository (Dockerfiles, scripts, configuration) is MIT.  
Moodle remains GPLv3+.
