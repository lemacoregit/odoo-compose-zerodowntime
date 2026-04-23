# Odoo 18 Blue-Green Deployment

> Zero-downtime automated deployment for Odoo 18 using GitHub Actions, Docker Compose Blue-Green strategy, and Nginx traffic switching.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [Prerequisites](#prerequisites)
- [Full Setup Guide](#full-setup-guide)
  - [Step 1 — Prepare the Server](#step-1--prepare-the-server)
  - [Step 2 — Clone Repositories](#step-2--clone-repositories)
  - [Step 3 — Configure Environment](#step-3--configure-environment)
  - [Step 4 — Start Docker Containers](#step-4--start-docker-containers)
  - [Step 5 — Set Up Nginx](#step-5--set-up-nginx)
  - [Step 6 — Issue SSL Certificate](#step-6--issue-ssl-certificate)
  - [Step 7 — Place Utility Scripts on Server](#step-7--place-utility-scripts-on-server)
  - [Step 8 — Configure GitHub Secrets](#step-8--configure-github-secrets)
  - [Step 9 — Trigger First Deployment](#step-9--trigger-first-deployment)
  - [Step 10 — Verify Everything](#step-10--verify-everything)
- [Port Reference](#port-reference)
- [Troubleshooting](#troubleshooting)

---

## Overview

This project deploys Odoo 18 with a **Blue-Green** strategy to achieve zero downtime. Every push to the `18.0` branch:

1. Detects which custom modules changed
2. Deploys the new version to the **standby** container
3. Validates it via health check before switching any traffic
4. Switches Nginx to the new container instantly
5. Shuts down the old container
6. Upgrades only the changed modules via XML-RPC
7. Sends an email notification

If the new container fails health checks, the pipeline aborts and the active container keeps running — no user impact.

---

## Architecture

```
Developer
    │ git push → 18.0
    ▼
GitHub Actions
    │
    ├─ detect-changes  (git diff → find __manifest__.py)
    │
    ├─ deploy
    │   ├─ SSH: git pull on server
    │   ├─ SSH: docker compose up standby container
    │   ├─ SSH: health check (max 90s)
    │   ├─ SSH: switch Nginx symlink + reload
    │   ├─ SSH: docker compose down active container
    │   └─ XML-RPC: upgrade changed modules
    │
    └─ notify  (HTML email → recipients)

                        ┌────────────────────────────────┐
                        │            Server              │
                        │                               │
                        │  ┌─────────────────────────┐  │
   User → HTTPS:443 ───────▶       Nginx              │  │
                        │  └────────────┬────────────┘  │
                        │               │ symlink        │
                        │        ┌──────▼──────┐         │
                        │        │   ACTIVE    │         │
                        │        │ (blue/green)│         │
                        │        └─────────────┘         │
                        │                               │
                        │        ┌─────────────┐         │
                        │        │   STANDBY   │         │
                        │        │  (sleeping) │         │
                        │        └─────────────┘         │
                        │                               │
                        │  ┌──────────┐ ┌──────────┐    │
                        │  │PostgreSQL│ │  Redis   │    │
                        │  └──────────┘ └──────────┘    │
                        └────────────────────────────────┘
```

---

## Documentation

Each component has its own dedicated README:

| File | Covers |
|---|---|
| [README.docker.md](README.docker.md) | Docker Compose setup, Blue-Green concept, volumes, network, environment variables, commands |
| [README.nginx.md](README.nginx.md) | Nginx config, traffic switching, SSL, setup.sh, switch.sh |
| [README.cicd.md](README.cicd.md) | GitHub Actions workflow, secrets, module detection, force upgrade, email notification |

---

## Prerequisites

**Server (Ubuntu 22.04+):**

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Docker Compose v2
sudo apt-get install docker-compose-plugin

# Nginx
sudo apt-get install nginx

# Certbot
sudo apt-get install certbot python3-certbot-nginx

# Netcat (for container health checks)
sudo apt-get install netcat-openbsd
```

**GitHub:**
- Repository with Odoo 18 custom modules
- GitHub Actions enabled
- Secrets configured (see [Step 8](#step-8--configure-github-secrets))

---

## Full Setup Guide

### Step 1 — Prepare the Server

SSH into your server and install all dependencies:

```bash
# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# Install Docker Compose plugin
sudo apt-get install -y docker-compose-plugin

# Install Nginx, Certbot, tools
sudo apt-get install -y nginx certbot python3-certbot-nginx netcat-openbsd git

# Verify versions
docker --version
docker compose version
nginx -v
```

---

### Step 2 — Clone Repositories

```bash
# Clone the docker compose project
sudo mkdir -p /opt/lemacore
sudo chown $USER:$USER /opt/lemacore
git clone https://github.com/your-org/docker-compose /opt/lemacore
cd /opt/lemacore

# Clone your custom addons repo inside the project
git clone https://github.com/your-org/mazuta-addons odoo/mazuta-custom-addons

# Create required directories (git-ignored)
mkdir -p odoo/logs
mkdir -p odoo/mazuta-extra-addons
mkdir -p odoo/default-addons
mkdir -p odoo-web/addons odoo-web/filestore odoo-web/sessions
mkdir -p odoo-postgres
mkdir -p odoo-redis/data odoo-redis/conf
```

---

### Step 3 — Configure Environment

```bash
cd /opt/lemacore

# Copy env template
cp .env.example .env

# Edit with your actual values
nano .env
```

At minimum, change these values:

```env
POSTGRES_USER=odoo
POSTGRES_PASSWORD=<strong_password>
POSTGRES_DB=odoo

ODOO_SESSION_REDIS_PASSWORD=<strong_redis_password>
ODOO_SESSION_REDIS_URL=redis://:<strong_redis_password>@redis:6379/0
```

Everything else can stay as the defaults in `.env.example`.

---

### Step 4 — Start Docker Containers

Always start **Green first** — it owns the network, database, and Redis.

```bash
cd /opt/lemacore

# Start green (db + redis + odoo-green)
docker compose -f docker-green.yml up -d

# Verify all containers are running
docker ps --filter name=odoo18-mazuta

# Expected output:
# odoo18-mazuta-green     → Up
# odoo18-mazuta-postgres  → Up
# odoo18-mazuta-redis     → Up
```

Wait ~30 seconds for Odoo to initialize, then test locally:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8118/web/health
# Expected: 200
```

---

### Step 5 — Set Up Nginx

```bash
# Run the one-time setup script
cd /opt/lemacore
sudo bash nginx-bluegreen/setup.sh
```

This will:
- Copy `odoo-blue` and `odoo-green` to `/etc/nginx/sites-available/`
- Activate blue as default via symlink
- Remove the default Nginx page
- Test and reload Nginx

Verify the symlink:

```bash
ls -la /etc/nginx/sites-enabled/odoo
# Should show: odoo -> /etc/nginx/sites-available/odoo-blue
```

> At this point Nginx is configured but SSL is not yet set up, so HTTPS will not work yet.

---

### Step 6 — Issue SSL Certificate

Make sure your domain (`erp.lemacore.com`) already points to the server IP via DNS before running this:

```bash
# Issue certificate — Certbot will auto-configure Nginx
sudo certbot --nginx -d erp.lemacore.com

# Verify auto-renewal works
sudo certbot renew --dry-run
```

After Certbot runs, test HTTPS:

```bash
curl -s -o /dev/null -w "%{http_code}" https://erp.lemacore.com/web/health
# Expected: 200
```

---

### Step 7 — Place Utility Scripts on Server

The CI/CD pipeline calls `switch.sh` and `upgrade_modules.py` on the server via SSH. Make sure they are in the expected paths:

```bash
# switch.sh is already part of the docker compose project
ls /opt/lemacore/nginx-bluegreen/switch.sh

# upgrade_modules.py — copy to the project root or a path of your choice
cp /path/to/upgrade_modules.py /opt/lemacore/upgrade_modules.py

# Verify switch.sh is executable
chmod +x /opt/lemacore/nginx-bluegreen/switch.sh

# Test switch manually
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh green
# Then switch back
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh blue
```

Also verify the SSH user has permission to run `nginx -s reload` without a password prompt (required for GitHub Actions):

```bash
# Add to sudoers (replace 'ubuntu' with your SSH user)
echo "ubuntu ALL=(ALL) NOPASSWD: /usr/sbin/nginx" | sudo tee /etc/sudoers.d/nginx-reload
```

---

### Step 8 — Configure GitHub Secrets

Go to your repository on GitHub:
**Settings → Secrets and variables → Actions → New repository secret**

Add all of the following:

**Server Access:**

| Secret | Value |
|---|---|
| `SSH_PRIVATE_KEY` | Contents of your private key (e.g. `cat ~/.ssh/id_rsa`) |
| `SSH_HOST` | Your server IP or hostname |
| `SSH_USER` | Your SSH username (e.g. `ubuntu`) |

**Paths on Server:**

| Secret | Value |
|---|---|
| `ODOO_ADDONS_PATH` | `/opt/lemacore/odoo/mazuta-custom-addons` |
| `COMPOSE_PROJECT_PATH` | `/opt/lemacore` |
| `NGINX_SWITCH_SCRIPT_PATH` | `/opt/lemacore/nginx-bluegreen/switch.sh` |
| `UPGRADE_SCRIPT_PATH` | `/opt/lemacore/upgrade_modules.py` |

**Odoo Connection:**

| Secret | Value |
|---|---|
| `ODOO_URL` | `https://erp.lemacore.com` |
| `ODOO_DB` | `odoo` |
| `ODOO_ADMIN_USER` | `admin` |
| `ODOO_ADMIN_PASSWORD` | Your Odoo admin password |

**Email Notification:**

| Secret | Value |
|---|---|
| `EMAIL_RECIPIENTS` | `dev@lemacore.com,ops@lemacore.com` |
| `SMTP_SERVER` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USER` | `noreply@lemacore.com` |
| `SMTP_PASSWORD` | Gmail App Password |
| `EMAIL_FROM` | `Odoo CI/CD <noreply@lemacore.com>` |

---

### Step 9 — Trigger First Deployment

Push a small change to the `18.0` branch to trigger the pipeline:

```bash
# In your custom addons repo (mazuta-custom-addons)
git checkout 18.0
echo "# trigger deploy" >> README.md
git add README.md
git commit -m "chore: trigger first CI/CD deploy"
git push origin 18.0
```

Go to **GitHub → Actions** to watch the workflow run.

Alternatively, use manual trigger:

1. **Actions → Odoo CI/CD - Auto Deploy & Upgrade → Run workflow**
2. Enter a module name in `force_modules` (e.g. `base`)
3. Click **Run workflow**

---

### Step 10 — Verify Everything

After a successful first deployment:

```bash
# Check active container (should have switched to blue after first deploy)
docker ps --filter name=odoo18-mazuta

# Check active Nginx config
ls -la /etc/nginx/sites-enabled/odoo

# Test public URL
curl -s -o /dev/null -w "%{http_code}" https://erp.lemacore.com/web/health
# Expected: 200

# Check Nginx logs
sudo tail -20 /var/log/nginx/odoo-blue.access.log

# Check Odoo logs
docker logs --tail 50 odoo18-mazuta-blue
```

---

## Port Reference

| Service | Host Port | Used by |
|---|---|---|
| Odoo Blue (web) | `8018` | Nginx → blue |
| Odoo Blue (longpoll) | `8172` | Nginx → blue longpolling |
| Odoo Green (web) | `8118` | Nginx → green |
| Odoo Green (longpoll) | `8272` | Nginx → green longpolling |
| PostgreSQL | `5016` | Internal / external DB tools |
| Redis | `5030` | Internal / external Redis tools |
| HTTPS (public) | `443` | All user traffic via Nginx |
| HTTP (public) | `80` | Redirects to HTTPS |

---

## Troubleshooting

**Containers not starting**

```bash
# Check logs
docker logs odoo18-mazuta-green
docker logs odoo18-mazuta-postgres

# Check env file is present
cat /opt/lemacore/.env
```

**Blue container fails — network not found**

Blue requires green's network to exist. Start green first:
```bash
docker compose -f docker-green.yml up -d
docker compose -f docker-blue.yml up -d
```

**Nginx returns 502 Bad Gateway**

The active container may not be running. Check and switch manually:
```bash
# See which is active
ls -la /etc/nginx/sites-enabled/odoo

# Check containers
docker ps | grep mazuta

# Switch to the running one
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh green
```

**Health check fails during deploy**

The pipeline aborts and keeps the active container running. Investigate the new container:
```bash
docker logs odoo18-mazuta-blue   # or green
docker logs odoo18-mazuta-blue-db-checker
```

**GitHub Actions SSH fails**

```bash
# Test SSH from your local machine
ssh -i your_key.pem ubuntu@your_server_ip "echo OK"

# Check the key format — must be OpenSSH format
head -1 your_key.pem
# Should be: -----BEGIN OPENSSH PRIVATE KEY-----
```

**Module upgrade fails**

Test manually from server or local:
```bash
python3 /opt/lemacore/upgrade_modules.py \
  --url https://erp.lemacore.com \
  --db odoo \
  --user admin \
  --password your_password \
  --modules your_module
```

**Email not received**

- Check spam folder
- For Gmail: use App Password, not account password
- Verify `SMTP_PORT` matches your provider (587 for STARTTLS, 465 for SSL)
- Check workflow logs for the `notify` job output