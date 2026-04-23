# Docker Compose Setup

> Blue-Green Docker Compose configuration for Odoo 18 with PostgreSQL, Redis, and shared volumes.

---

## Table of Contents

- [Overview](#overview)
- [Blue-Green Concept](#blue-green-concept)
- [Project Structure](#project-structure)
- [Compose Files](#compose-files)
  - [docker-green.yml](#docker-greenyml)
  - [docker-blue.yml](#docker-blueyml)
- [Environment Variables](#environment-variables)
- [Odoo Configuration](#odoo-configuration)
- [Volumes](#volumes)
- [Network](#network)
- [Commands Reference](#commands-reference)

---

## Overview

The Docker setup consists of two compose files representing **Blue** and **Green** environments. Both share the same PostgreSQL database, Redis instance, filestore, and custom addons — only the Odoo container itself is swapped during deployment.

```
docker-green.yml  →  db + redis + odoo-green (port 8118 / longpoll 8272)
docker-blue.yml   →  odoo-blue only (port 8018 / longpoll 8172)
```

At any given time, only one Odoo container is receiving traffic. The other is either stopped or being prepared for the next deployment.

---

## Blue-Green Concept

```
          Nginx (active symlink)
                  │
      ┌───────────┴───────────┐
      │                       │
 ┌────▼────┐             ┌────▼────┐
 │  BLUE   │             │  GREEN  │
 │  :8018  │             │  :8118  │
 └─────────┘             └─────────┘
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

1. Green is the default active container on first setup
2. On every deploy, the pipeline targets the **standby** container
3. After a successful health check, Nginx switches to the new container
4. The previously active container is stopped
5. On the next deploy, roles are reversed

---

## Project Structure

```
/opt/lemacore/
├── docker-green.yml              ← Primary compose (owns network, db, redis)
├── docker-blue.yml               ← Secondary compose (joins existing network)
├── .env                          ← Active environment file (never commit)
├── .env.example                  ← Template for .env
├── entrypoint.sh                 ← Custom Odoo entrypoint
├── odoo/
│   ├── odoo.conf                 ← Shared Odoo config (blue & green)
│   ├── logs/                     ← Log output (git-ignored)
│   ├── custom-addons/            ← Custom modules repo
│   └── default-addons/           ← Odoo core addons
├── etc/
│   ├── requirements.txt          ← Python packages installed at startup
│   ├── addons/                   ← Compiled web assets (git-ignored)
│   ├── filestore/                ← Odoo attachments (git-ignored)
│   └── sessions/                 ← Session files (git-ignored)
├── odoo-postgres/                ← PostgreSQL data directory (git-ignored)
└── odoo-redis/
    ├── data/                     ← Redis persistence (git-ignored)
    └── conf/                     ← Redis config (git-ignored)
```

---

## Compose Files

### docker-green.yml

Green is the **owner** of shared infrastructure. It creates the Docker network and runs:

| Container | Image | Role |
|---|---|---|
| `odoo18-zerodowntime-postgres` | `postgres:16` | Database |
| `odoo18-zerodowntime-redis` | `redis:latest` | Session store |
| `odoo18-zerodowntime-green` | `odoo:18.0` | Odoo web (port 8118) |

**Port mapping:**

| Service | Host Port | Container Port |
|---|---|---|
| Odoo web | `8118` (`ODOO_GREEN_HTTP_PORT`) | `8069` |
| Longpolling | `8272` (`ODOO_GREEN_LONGPOLLING_PORT`) | `8072` |
| PostgreSQL | `5016` (`POSTGRES_PORT`) | `5432` |
| Redis | `5030` (`REDIS_EXTERNAL_PORT`) | `6379` |

**Start green:**
```bash
docker compose -f docker-green.yml up -d
```

**Stop green:**
```bash
docker compose -f docker-green.yml down
```

> **Warning:** Stopping green also stops PostgreSQL and Redis. Only stop green when blue is not running, or when doing a full shutdown.

---

### docker-blue.yml

Blue is the **secondary** compose file. It joins the existing network created by green and runs:

| Container | Image | Role |
|---|---|---|
| `odoo18-zerodowntime-blue-db-checker` | `busybox` | Waits for db to be ready |
| `odoo18-zerodowntime-blue` | `odoo:18.0` | Odoo web (port 8018) |

**Port mapping:**

| Service | Host Port | Container Port |
|---|---|---|
| Odoo web | `8018` (`ODOO_BLUE_HTTP_PORT`) | `8069` |
| Longpolling | `8172` (`ODOO_BLUE_LONGPOLLING_PORT`) | `8072` |

**Start blue:**
```bash
docker compose -f docker-blue.yml up -d
```

**Stop blue:**
```bash
docker compose -f docker-blue.yml down
```

> **Note:** Blue requires green's network (`odoo18-zerodowntime-network`) and database to already be running. Always start green first.

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
| `POSTGRES_DB` | PostgreSQL database name | `odoo` |
| `POSTGRES_PORT` | PostgreSQL host port | `5016` |
| `ODOO_BLUE_HTTP_PORT` | Blue Odoo web host port | `8018` |
| `ODOO_BLUE_LONGPOLLING_PORT` | Blue longpolling host port | `8172` |
| `ODOO_GREEN_HTTP_PORT` | Green Odoo web host port | `8118` |
| `ODOO_GREEN_LONGPOLLING_PORT` | Green longpolling host port | `8272` |
| `REDIS_EXTERNAL_PORT` | Redis host port | `5030` |
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

`odoo/odoo.conf` is mounted into both blue and green containers at `/etc/odoo/odoo.conf`. Both containers share the same config file.

**Key settings explained:**

```ini
[options]
; Internal container ports — do NOT change these to match host ports
xmlrpc_port = 8069
gevent_port = 8072
longpolling_port = 8072

; Must be True when behind Nginx reverse proxy
proxy_mode = True

; Addons path inside the container (mapped via volumes)
addons_path = /mnt/default-addons, /mnt/custom-addons

; Data directory — filestore, sessions are stored here
data_dir = /etc/odoo

; Worker processes — set based on available CPU cores
; Recommended: (CPU cores * 2) + 1
workers = 4
```

> **Important:** The host ports (`8018`, `8118`, `8172`, `8272`) are defined in the compose files via `ports`. The `odoo.conf` always uses the internal container port `8069` and `8072`.

---

## Volumes

All data volumes are shared between blue and green via bind mounts pointing to the same host directories:

| Volume (host path) | Container path | Description |
|---|---|---|
| `./odoo/odoo.conf` | `/etc/odoo/odoo.conf` | Odoo configuration |
| `./odoo/logs` | `/etc/odoo/logs` | Log files |
| `./etc/addons` | `/etc/odoo/addons` | Web assets |
| `./etc/filestore` | `/etc/odoo/filestore` | File attachments |
| `./etc/sessions` | `/etc/odoo/sessions` | Session data |
| `./etc/requirements.txt` | `/etc/odoo/requirements.txt` | Python packages |
| `./odoo/custom-addons` | `/mnt/custom-addons` | Custom modules |
| `./odoo/default-addons` | `/mnt/default-addons` | Core Odoo addons |
| `./entrypoint.sh` | `/entrypoint.sh` | Startup script |

---

## Network

Both blue and green communicate through a single bridge network:

```
Name:   odoo18-zerodowntime-network
Driver: bridge
Owner: docker-green.yml (creates it)
```

Blue joins as `external: true`, meaning Docker will fail to start blue if the network does not exist. Always ensure green is running before starting blue.

---

## Commands Reference

```bash
# Start green (first time or after full shutdown)
docker compose -f docker-green.yml up -d

# Start blue (requires green's network to exist)
docker compose -f docker-blue.yml up -d

# Stop blue only (safe — green keeps running)
docker compose -f docker-blue.yml down

# Stop everything (full shutdown)
docker compose -f docker-blue.yml down
docker compose -f docker-green.yml down

# View logs
docker logs -f odoo18-zerodowntime-green
docker logs -f odoo18-zerodowntime-blue

# Restart a specific Odoo container
docker compose -f docker-green.yml restart odoo
docker compose -f docker-blue.yml restart odoo

# Pull latest Odoo image
docker compose -f docker-green.yml pull odoo
docker compose -f docker-blue.yml pull odoo

# Check running containers
docker ps --filter name=odoo18-zerodowntime
```
