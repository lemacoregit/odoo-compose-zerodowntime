# Odoo 18 Zero-Downtime Deployment

> Automated zero-downtime deployment for Odoo 18 using GitHub Actions, Docker Compose primary/standby strategy, and Nginx traffic switching via symlink reload.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [Prerequisites](#prerequisites)
- [Full Setup Guide](#full-setup-guide)
  - [Step 1 — Prepare the Server](#step-1--prepare-the-server)
  - [Step 2 — Clone Repository](#step-2--clone-repository)
  - [Step 3 — Create Required Directories](#step-3--create-required-directories)
  - [Step 4 — Configure Environment](#step-4--configure-environment)
  - [Step 5 — Start Docker Containers](#step-5--start-docker-containers)
  - [Step 6 — Set Up Nginx and SSL](#step-6--set-up-nginx-and-ssl)
  - [Step 7 — Configure GitHub Secrets](#step-7--configure-github-secrets)
  - [Step 8 — Trigger First Deployment](#step-8--trigger-first-deployment)
  - [Step 9 — Verify Everything](#step-9--verify-everything)
- [Port Reference](#port-reference)
- [Troubleshooting](#troubleshooting)

---

## Overview

Every push to the `main` branch triggers the pipeline:

1. Detects which custom Odoo modules changed
2. Deploys the new version to the **standby** container (not yet receiving traffic)
3. Runs health checks against the standby container — max 90 seconds
4. If healthy: switches Nginx to standby (graceful reload, zero dropped connections)
5. Stops the previously active container
6. Upgrades only the changed modules via XML-RPC
7. Sends an HTML email notification (success or failure)

If the standby container fails health checks, the pipeline aborts — the active container keeps serving traffic with no user impact.

Manual rollback is available via `workflow_dispatch → action: rollback`.

---

## Architecture

```
Developer
    │ git push → main
    ▼
GitHub Actions
    │
    ├─ detect-changes  (git diff → find __manifest__.py, depth-independent)
    │
    ├─ deploy
    │   ├─ SSH: git pull addons on server
    │   ├─ SSH: docker compose up <next-slot>
    │   ├─ SSH: health check (max 94s)
    │   ├─ SSH: switch Nginx symlink + reload
    │   ├─ SSH: docker compose stop <previous-slot>
    │   └─ XML-RPC: upgrade changed modules (with retry + verify)
    │
    ├─ rollback  (workflow_dispatch only — switches Nginx back to previous slot)
    │
    └─ notify  (HTML email → recipients, always runs)

                    ┌─────────────────────────────────────┐
                    │               Server                │
                    │                                     │
                    │  ┌──────────────────────────────┐   │
 User → HTTPS:443 ────▶         Nginx :443             │   │
                    │  └──────────────┬───────────────┘   │
                    │                 │ symlink            │
                    │         ┌───────▼───────┐            │
                    │         │    ACTIVE     │            │
                    │         │ primary/stby  │            │
                    │         └───────────────┘            │
                    │                                     │
                    │         ┌───────────────┐            │
                    │         │    STANDBY    │            │
                    │         │   (stopped)   │            │
                    │         └───────────────┘            │
                    │                                     │
                    │  ┌────────────┐  ┌──────────────┐   │
                    │  │ PostgreSQL │  │    Redis     │   │
                    │  │  (shared)  │  │   (shared)   │   │
                    │  └────────────┘  └──────────────┘   │
                    └─────────────────────────────────────┘
```

---

## Documentation

Each component has its own detailed README:

| Folder | README | Covers |
|---|---|---|
| `docker/` | [docker/README.md](docker/README.md) | Docker Compose setup, primary/standby concept, volumes, network, environment variables, commands |
| `nginx/` | [nginx/README.md](nginx/README.md) | Nginx config features, traffic switching, SSL, setup.sh, switch.sh, shutdown.sh |
| `github/` | [github/README.md](github/README.md) | GitHub Actions workflow, secrets, module detection, force upgrade, rollback, email notification |

---

## Prerequisites

**Server (Ubuntu 22.04+):**

```bash
# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Docker Engine
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# Docker Compose v2 plugin
sudo apt-get install -y docker-compose-plugin

# Nginx
sudo apt-get install -y nginx

# Certbot (Let's Encrypt)
sudo apt-get install -y certbot python3-certbot-nginx

# Tools
sudo apt-get install -y git curl

# Verify versions
docker --version
docker compose version
nginx -v
```

**GitHub:**
- Repository with this project (or at minimum `github/deploy.yml` in `.github/workflows/`)
- GitHub Actions enabled
- Secrets configured (see [Step 7](#step-7--configure-github-secrets))

---

## Full Setup Guide

### Step 1 — Prepare the Server

Run the commands in [Prerequisites](#prerequisites) above on a fresh Ubuntu 22.04+ server.

---

### Step 2 — Clone Repository

```bash
sudo mkdir -p /opt/zerodowntime
sudo chown $USER:$USER /opt/zerodowntime

git clone https://github.com/your-org/docker-zero-downtime /opt/zerodowntime
cd /opt/zerodowntime
```

---

### Step 3 — Create Required Directories

These directories are git-ignored (runtime data):

```bash
cd /opt/zerodowntime/docker

# Odoo runtime data
mkdir -p etc/addons etc/filestore etc/sessions etc/logs

# PostgreSQL data
mkdir -p odoo-postgres

# Odoo core addons (download or copy separately)
mkdir -p addons/default

# Custom addons — clone your module repo here
# git clone https://github.com/your-org/your-addons addons/custom
```

---

### Step 4 — Configure Environment

```bash
cd /opt/zerodowntime/docker

cp .env.example .env
nano .env
```

Minimum required changes:

```env
POSTGRES_PASSWORD=your_strong_password

ODOO_SESSION_REDIS_PASSWORD=your_redis_password
ODOO_SESSION_REDIS_URL=redis://:your_redis_password@redis:6379/0
```

Then edit `etc/conf/odoo.conf` — update at minimum:

```ini
admin_passwd = your_strong_master_password
```

---

### Step 5 — Start Docker Containers

```bash
cd /opt/zerodowntime/docker

# Start infra + primary Odoo
docker compose up -d

# Wait ~30s then check
docker compose ps
```

Expected output:

```
NAME                            STATUS
odoo18-zerodowntime-postgres    Up (healthy)
odoo18-zerodowntime-redis       Up (healthy)
odoo18-zerodowntime-primary     Up (healthy)
```

Test locally:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8318/web/health
# Expected: 200
```

---

### Step 6 — Set Up Nginx and SSL

Make sure your domain (`zerodowntime.lemacore.com`) already points to this server's IP via DNS **before** running this.

```bash
cd /opt/zerodowntime
sudo bash nginx/setup.sh
```

`setup.sh` does everything in one run:

1. Checks that `nginx` and `certbot` are installed
2. Obtains a Let's Encrypt certificate via `certbot --standalone`
3. Installs `odoo18-compose-primary` and `odoo18-compose-standby` to `/etc/nginx/sites-available/`
4. Activates primary as default via symlink
5. Creates `/var/www/certbot` for future webroot renewals
6. Validates config (`nginx -t`) and starts Nginx
7. Writes `/etc/sudoers.d/odoo-nginx` so the deploy user can reload Nginx without a password

Verify after setup:

```bash
# Check active symlink
readlink /etc/nginx/sites-enabled/odoo18-zerodowntime
# Expected: /etc/nginx/sites-available/odoo18-compose-primary

# Test HTTPS
curl -s -o /dev/null -w "%{http_code}" https://zerodowntime.lemacore.com/web/health
# Expected: 200
```

---

### Step 7 — Configure GitHub Secrets

Go to: **Repository → Settings → Secrets and variables → Actions → New repository secret**

**Server Access:**

| Secret | Value |
|---|---|
| `SSH_PRIVATE_KEY` | OpenSSH private key — `cat ~/.ssh/id_ed25519` |
| `SSH_HOST` | Server IP or hostname |
| `SSH_USER` | SSH username (e.g. `ubuntu`) |

**Paths on Server:**

| Secret | Value |
|---|---|
| `ODOO_ADDONS_PATH` | `/opt/zerodowntime/docker/addons/custom` |
| `COMPOSE_PROJECT_PATH` | `/opt/zerodowntime` |
| `NGINX_SWITCH_SCRIPT_PATH` | `/opt/zerodowntime/nginx/switch.sh` |

**Odoo Connection:**

| Secret | Value |
|---|---|
| `ODOO_URL` | `https://zerodowntime.lemacore.com` |
| `ODOO_DB` | `odoo` |
| `ODOO_ADMIN_USER` | `admin` |
| `ODOO_ADMIN_PASSWORD` | Odoo admin password |

**Email Notification:**

| Secret | Value |
|---|---|
| `EMAIL_RECIPIENTS` | `dev@zerodowntime.com,ops@zerodowntime.com` |
| `SMTP_SERVER` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USER` | `noreply@zerodowntime.com` |
| `SMTP_PASSWORD` | Gmail App Password |
| `EMAIL_FROM` | `Odoo CI/CD <noreply@zerodowntime.com>` |

Also place the workflow file on GitHub:

```bash
# In your repo, copy the workflow to the correct location
mkdir -p .github/workflows
cp github/deploy.yml .github/workflows/deploy.yml
git add .github/workflows/deploy.yml
git commit -m "ci: add odoo zero-downtime deployment workflow"
git push
```

---

### Step 8 — Trigger First Deployment

Push any change to `main` to trigger the pipeline automatically.

Or use manual trigger:

1. **GitHub → Actions → Odoo CI/CD - Auto Deploy & Upgrade → Run workflow**
2. Leave `force_modules` empty (auto-detect) or enter a module name
3. Leave `action` as `deploy`
4. Click **Run workflow**

Watch the pipeline at **GitHub → Actions**.

---

### Step 9 — Verify Everything

After a successful first deployment, the standby slot becomes active:

```bash
# Check running containers
docker ps --filter name=odoo18-zerodowntime

# Check active Nginx config (should now point to standby after first deploy)
readlink /etc/nginx/sites-enabled/odoo18-zerodowntime

# Test public URL
curl -s -o /dev/null -w "%{http_code}" https://zerodowntime.lemacore.com/web/health
# Expected: 200

# Check Nginx access log
sudo tail -20 /var/log/nginx/odoo-standby.access.log

# Check Odoo logs
docker logs --tail 50 odoo18-zerodowntime-standby
```

---

## Port Reference

| Service | Host Port | Notes |
|---|---|---|
| Odoo Primary (web) | `8318` | Nginx → primary |
| Odoo Primary (longpoll) | `8327` | Nginx → primary longpolling |
| Odoo Standby (web) | `8418` | Nginx → standby |
| Odoo Standby (longpoll) | `8427` | Nginx → standby longpolling |
| PostgreSQL | `5016` | External DB tools access |
| Redis | `6030` | External Redis tools access |
| HTTPS (public) | `443` | All user traffic via Nginx |
| HTTP (public) | `80` | Redirects to HTTPS |

---

## Troubleshooting

**Containers not starting**

```bash
docker logs odoo18-zerodowntime-primary
docker logs odoo18-zerodowntime-postgres
docker logs odoo18-zerodowntime-redis

# Check env file
cat /opt/zerodowntime/docker/.env
```

**Standby container fails — network not found**

The standby requires the network created by the primary compose. Always start primary first:

```bash
cd /opt/zerodowntime/docker
docker compose up -d
docker compose -f docker-compose.yml -f docker-compose.standby.yml up -d odoo-standby
```

**Nginx returns 502 Bad Gateway**

The active container may not be running:

```bash
# Check active slot
readlink /etc/nginx/sites-enabled/odoo18-zerodowntime

# Check containers
docker ps --filter name=odoo18-zerodowntime

# Switch to the running slot
sudo bash /opt/zerodowntime/nginx/switch.sh primary
# or
sudo bash /opt/zerodowntime/nginx/switch.sh standby
```

**Health check fails during deploy**

The pipeline aborts and keeps the active container running. Check the failed container:

```bash
docker logs odoo18-zerodowntime-standby
docker logs odoo18-zerodowntime-primary
```

**Manual rollback needed**

Use the GitHub Actions manual trigger:

1. **Actions → Odoo CI/CD → Run workflow**
2. Set `action` to `rollback`
3. Click **Run workflow**

Or roll back manually on the server:

```bash
sudo bash /opt/zerodowntime/nginx/switch.sh primary
# or
sudo bash /opt/zerodowntime/nginx/switch.sh standby
```

**GitHub Actions SSH fails**

```bash
# Test from local machine
ssh -i your_key ubuntu@your_server_ip "echo OK"

# Key format must be OpenSSH
head -1 your_key
# Expected: -----BEGIN OPENSSH PRIVATE KEY-----
```

**Module upgrade fails**

Run the script manually from any machine with network access to Odoo:

```bash
python3 github/script/upgrade_modules.py \
  --url https://zerodowntime.lemacore.com \
  --db odoo \
  --user admin \
  --password your_password \
  --modules your_module_name
```

**Email not received**

- Check spam folder
- For Gmail: use App Password (not account password) — [Google Account → Security → App Passwords](https://myaccount.google.com/apppasswords)
- Verify `SMTP_PORT`: `587` for STARTTLS, `465` for SSL
- Check workflow logs under the `notify` job

**Remove Nginx config (decommission)**

```bash
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes
# With log cleanup:
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes --purge-logs
```
