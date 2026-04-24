# Docker Compose Setup

> Zero-downtime Docker Compose configuration for Odoo 18 with PostgreSQL, Redis, and shared volumes.

---

## Table of Contents

- [Quick Deploy](#quick-deploy)
- [Overview](#overview)
- [Deployment Concept](#deployment-concept)
- [Project Structure](#project-structure)
- [Compose Files](#compose-files)
  - [docker-compose.yml](#docker-composeyml)
  - [docker-compose.standby.yml](#docker-composestandbyyml)
  - [docker-compose.override.yml](#docker-composeoverrideyml)
- [Environment Variables](#environment-variables)
- [Odoo Configuration](#odoo-configuration)
- [Volumes](#volumes)
- [Network](#network)
- [Commands Reference](#commands-reference)

---

## Quick Deploy

Step-by-step guide to deploy from scratch on a new server.

### Step 1 — Clone project

```bash
sudo mkdir -p /opt/zerodowntime
sudo chown $USER:$USER /opt/zerodowntime
git clone https://github.com/your-org/docker-zero-downtime /opt/zerodowntime
cd /opt/zerodowntime/docker
```

### Step 2 — Create required directories

```bash
# Data directories (git-ignored)
mkdir -p etc/addons etc/filestore etc/sessions etc/logs
mkdir -p odoo-postgres
mkdir -p addons/default

# Custom & extra addons — clone or copy your modules here
# mkdir -p addons/custom addons/extra  ← already in repo
```

### Step 3 — Configure environment

```bash
cp .env.example .env
nano .env
```

Minimum **required** changes:

```env
POSTGRES_PASSWORD=your_strong_password

ODOO_SESSION_REDIS_PASSWORD=your_redis_password
ODOO_SESSION_REDIS_URL=redis://:your_redis_password@redis:6379/0
```

### Step 4 — Configure Odoo

Edit `etc/conf/odoo.conf` — update at minimum these two values:

```ini
admin_passwd = your_strong_master_password
```

### Step 5 — Start containers

```bash
# Run from inside the docker/ folder
docker compose up -d

# Wait ~30 seconds then check status
docker compose ps
```

Expected output:

```
NAME                            STATUS
odoo18-zerodowntime-postgres    Up (healthy)
odoo18-zerodowntime-redis       Up (healthy)
odoo18-zerodowntime-primary     Up (healthy)
```

### Step 6 — Verify Odoo is running

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8318/web/health
# Expected: 200
```

### Step 7 — Check logs if something is wrong

```bash
# Odoo
docker logs --tail 50 odoo18-zerodowntime-primary

# Database
docker logs --tail 20 odoo18-zerodowntime-postgres

# Redis
docker logs --tail 20 odoo18-zerodowntime-redis
```

---

## Overview

The Docker setup uses three compose files. The primary file owns the shared infrastructure and the active Odoo instance. The standby file runs the second Odoo instance used during deployments.

```
docker-compose.yml          →  db + redis + odoo-primary  (port 8318 / longpoll 8327)
docker-compose.standby.yml  →  odoo-standby only          (port 8418 / longpoll 8427)
docker-compose.override.yml →  local dev overrides        (auto-merged, git-ignored)
```

At any given time, only one Odoo container is receiving traffic. The other is either stopped or being prepared for the next deployment.

---

## Deployment Concept

```
          Nginx (active symlink)
                  │
      ┌───────────┴───────────┐
      │                       │
 ┌────▼──────┐         ┌──────▼────┐
 │  PRIMARY  │         │  STANDBY  │
 │   :8318   │         │   :8418   │
 └───────────┘         └───────────┘
      │                       │
      └───────────┬───────────┘
                  │
        ┌─────────▼─────────┐
        │    PostgreSQL      │  (shared)
        │    Redis           │  (shared)
        │    Filestore       │  (shared)
        │    Custom Addons   │  (shared)
        └───────────────────┘
```

**How it works:**

1. Primary is the default active container on first setup
2. On every deploy, the pipeline targets the **standby** slot
3. After a successful health check, Nginx switches to the standby slot
4. The previously active slot is stopped
5. On the next deploy, roles reverse

---

## Project Structure

```
docker/
├── docker-compose.yml              ← Primary compose (owns network, db, redis, odoo-primary)
├── docker-compose.standby.yml      ← Standby compose (joins existing network, odoo-standby only)
├── docker-compose.override.yml     ← Local dev overrides (never commit — git-ignored)
├── .env                            ← Active environment file (never commit — git-ignored)
├── .env.example                    ← Template for .env
├── entrypoint.sh                   ← Custom Odoo entrypoint script
├── addons/
│   ├── custom/                     ← Custom project modules (git submodule or clone)
│   ├── extra/                      ← Extra/community modules
│   └── default/                    ← Odoo core addons (git-ignored, download separately)
├── etc/
│   ├── conf/
│   │   ├── odoo.conf               ← Odoo configuration (shared by primary & standby)
│   │   └── redis.conf              ← Redis configuration
│   ├── requirements.txt            ← Python packages installed at container startup
│   ├── addons/                     ← Compiled web assets (git-ignored)
│   ├── filestore/                  ← Odoo file attachments (git-ignored)
│   ├── sessions/                   ← Session files (git-ignored, unused — Redis handles sessions)
│   └── logs/                       ← Odoo log output (git-ignored)
└── odoo-postgres/                  ← PostgreSQL data directory (git-ignored)
```

---

## Compose Files

### docker-compose.yml

The primary compose file. Creates the Docker network and runs all shared infrastructure plus the primary Odoo instance.

| Container | Image | Role |
|---|---|---|
| `odoo18-zerodowntime-postgres` | `postgres:16` | Database |
| `odoo18-zerodowntime-redis` | `redis:8.2.5` | Session store |
| `odoo18-zerodowntime-primary` | `odoo:18.0` | Odoo web (port 8318) |

**Port mapping:**

| Service | Host Port | Container Port |
|---|---|---|
| Odoo web | `8318` (`ODOO_PRIMARY_HTTP_PORT`) | `8069` |
| Longpolling | `8327` (`ODOO_PRIMARY_LONGPOLLING_PORT`) | `8072` |
| PostgreSQL | `5016` (`POSTGRES_PORT`) | `5432` |
| Redis | `6030` (`REDIS_EXTERNAL_PORT`) | `6379` |

```bash
# Bootstrap — start infra + primary odoo
docker compose up -d

# Stop primary odoo only (infra keeps running)
docker compose stop odoo-primary

# Full shutdown
docker compose down
```

> **Warning:** `docker compose down` stops PostgreSQL and Redis. Only run when also stopping the standby or doing a full shutdown.

---

### docker-compose.standby.yml

The standby compose file. Always combined with the primary file. Joins the existing network and runs only the standby Odoo instance.

| Container | Image | Role |
|---|---|---|
| `odoo18-zerodowntime-standby-db-checker` | `busybox` | Waits for db to be ready |
| `odoo18-zerodowntime-standby` | `odoo:18.0` | Odoo web (port 8418) |

**Port mapping:**

| Service | Host Port | Container Port |
|---|---|---|
| Odoo web | `8418` (`ODOO_STANDBY_HTTP_PORT`) | `8069` |
| Longpolling | `8427` (`ODOO_STANDBY_LONGPOLLING_PORT`) | `8072` |

```bash
# Start standby odoo
docker compose -f docker-compose.yml -f docker-compose.standby.yml up -d odoo-standby

# Stop standby odoo
docker compose -f docker-compose.yml -f docker-compose.standby.yml stop odoo-standby
```

> **Note:** Standby requires the network and database created by `docker-compose.yml`. Always ensure the primary compose is up before starting standby.

---

### docker-compose.override.yml

Auto-merged by Docker Compose when running `docker compose up` without explicit `-f` flags. Used for local development only — this file is git-ignored and should never be committed.

```bash
# Auto-merges override.yml — no extra flags needed
docker compose up -d
```

---

## Environment Variables

Copy `.env.example` to `.env` before starting any container:

```bash
cp .env.example .env
```

| Variable | Description | Example |
|---|---|---|
| `POSTGRES_USER` | PostgreSQL username | `odoo` |
| `POSTGRES_PASSWORD` | PostgreSQL password | `your_strong_password` |
| `POSTGRES_PORT` | PostgreSQL host port | `5016` |
| `ODOO_PRIMARY_HTTP_PORT` | Primary Odoo web host port | `8318` |
| `ODOO_PRIMARY_LONGPOLLING_PORT` | Primary longpolling host port | `8327` |
| `ODOO_STANDBY_HTTP_PORT` | Standby Odoo web host port | `8418` |
| `ODOO_STANDBY_LONGPOLLING_PORT` | Standby longpolling host port | `8427` |
| `REDIS_EXTERNAL_PORT` | Redis host port | `6030` |
| `ODOO_SESSION_REDIS` | Enable Redis session (`1` = yes) | `1` |
| `ODOO_SESSION_REDIS_HOST` | Redis hostname (internal) | `redis` |
| `ODOO_SESSION_REDIS_PORT` | Redis internal port | `6379` |
| `ODOO_SESSION_REDIS_PASSWORD` | Redis password | `your_redis_password` |
| `ODOO_SESSION_REDIS_SSL` | Enable Redis SSL | `false` |
| `ODOO_SESSION_REDIS_CLUSTER` | Enable Redis cluster mode | `false` |
| `ODOO_SESSION_REDIS_URL` | Full Redis connection URL | `redis://:pass@redis:6379/0` |
| `ODOO_SESSION_REDIS_PREFIX` | Redis session key prefix | `zerodowntime` |
| `ODOO_SESSION_REDIS_EXPIRATION` | Session TTL in seconds | `604800` |
| `ODOO_SESSION_REDIS_EXPIRATION_ANONYMOUS` | Anonymous session TTL | `10800` |

---

## Odoo Configuration

`etc/conf/odoo.conf` is mounted into both primary and standby containers at `/etc/odoo/odoo.conf`. Both containers share the same config file.

**Key settings explained:**

```ini
[options]
; Master password for the Odoo database manager — change this
admin_passwd = your_master_password

; Addons loaded in order: default (core) → extra (community) → custom (project)
addons_path = /mnt/default-addons, /mnt/extra-addons, /mnt/custom-addons

; Restrict Odoo to this database only
dbfilter = ^d$

; Disable database manager on login page — critical for production
list_db = False

; Must be True when behind Nginx reverse proxy
proxy_mode = True

; Worker processes — recommended: (CPU cores * 2) + 1
workers = 4

; Internal container ports — do NOT change to match host ports
xmlrpc_port = 8069
longpolling_port = 8072
```

> **Important:** The host ports (`8318`, `8327`, `8418`, `8427`) are defined in `.env` and used by the compose files. The `odoo.conf` always uses the internal container ports `8069` and `8072`.

---

## Volumes

All volumes are shared between primary and standby via bind mounts pointing to the same host directories:

| Host path | Container path | Description |
|---|---|---|
| `./entrypoint.sh` | `/entrypoint.sh` | Startup script |
| `./etc/conf/odoo.conf` | `/etc/odoo/odoo.conf` | Odoo configuration |
| `./etc/logs` | `/etc/odoo/logs` | Log files |
| `./etc/addons` | `/etc/odoo/addons` | Compiled web assets |
| `./etc/filestore` | `/etc/odoo/filestore` | File attachments |
| `./etc/sessions` | `/etc/odoo/sessions` | Session files |
| `./etc/requirements.txt` | `/etc/odoo/requirements.txt` | Python packages |
| `./addons/custom` | `/mnt/custom-addons` | Custom project modules |
| `./addons/extra` | `/mnt/extra-addons` | Extra/community modules |
| `./addons/default` | `/mnt/default-addons` | Odoo core addons |

---

## Network

Primary and standby communicate through a single bridge network:

```
Name:   odoo18-zerodowntime-network
Driver: bridge
Owner:  docker-compose.yml (creates it)
```

`docker-compose.standby.yml` joins as `external: true` — Docker will fail to start standby if the network does not exist. Always ensure `docker-compose.yml` is up before starting the standby.

---

## Commands Reference

```bash
# Bootstrap (first time) — starts infra + primary odoo
docker compose up -d

# Start standby odoo (requires primary network to exist)
docker compose -f docker-compose.yml -f docker-compose.standby.yml up -d odoo-standby

# Stop standby only (primary keeps running)
docker compose -f docker-compose.yml -f docker-compose.standby.yml stop odoo-standby

# Stop primary odoo only (infra keeps running)
docker compose stop odoo-primary

# Full shutdown
docker compose -f docker-compose.yml -f docker-compose.standby.yml down
docker compose down

# View logs (follow)
docker logs -f odoo18-zerodowntime-primary
docker logs -f odoo18-zerodowntime-standby
docker logs -f odoo18-zerodowntime-postgres

# Restart a specific container
docker compose restart odoo-primary
docker compose -f docker-compose.yml -f docker-compose.standby.yml restart odoo-standby

# Pull latest Odoo image
docker compose pull odoo-primary
docker compose -f docker-compose.yml -f docker-compose.standby.yml pull odoo-standby

# Check running containers
docker ps --filter name=odoo18-zerodowntime

# Check compose status
docker compose ps
docker compose -f docker-compose.yml -f docker-compose.standby.yml ps
```
