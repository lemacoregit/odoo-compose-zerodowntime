# Nginx Configuration

> Nginx reverse proxy for Odoo 18 zero-downtime deployment. Traffic switching between primary and standby slots via symlink + reload — zero dropped connections.

---

## Table of Contents

- [Overview](#overview)
- [How Traffic Switching Works](#how-traffic-switching-works)
- [Port Mapping](#port-mapping)
- [File Structure](#file-structure)
- [Nginx Config Features](#nginx-config-features)
- [Scripts](#scripts)
  - [setup.sh](#setupsh)
  - [switch.sh](#switchsh)
  - [resetup.sh](#resetupsh)
  - [shutdown.sh](#shutdownsh)
- [SSL Certificate](#ssl-certificate)
- [Sudoers Setup](#sudoers-setup)
- [Commands Reference](#commands-reference)

---

## Overview

Nginx sits in front of the two Odoo containers (primary and standby). Only one is receiving traffic at any given time. The active config is determined by a single symlink in `sites-enabled/`.

```
User Browser
     │ HTTPS :443
     ▼
  Nginx
     │
     │ /etc/nginx/sites-enabled/odoo18-zerodowntime  (symlink)
     │
     ├── → odoo18-compose-primary  (port 8018/8027)
     └── → odoo18-compose-standby  (port 8118/8127)
```

Switching traffic = update symlink + `nginx -s reload`. The reload is graceful — active connections are not dropped.

---

## How Traffic Switching Works

```bash
# Primary is active (default after setup)
/etc/nginx/sites-enabled/odoo18-zerodowntime -> /etc/nginx/sites-available/odoo18-compose-primary

# Standby is active (after first deploy)
/etc/nginx/sites-enabled/odoo18-zerodowntime -> /etc/nginx/sites-available/odoo18-compose-standby
```

The `switch.sh` script handles this atomically:

```bash
ln -sf /etc/nginx/sites-available/odoo18-compose-standby \
       /etc/nginx/sites-enabled/odoo18-zerodowntime
nginx -t && nginx -s reload
```

---

## Port Mapping

| Slot | Web (host) | Longpolling (host) | Container web | Container longpoll |
|---|---|---|---|---|
| Primary | `8018` | `8027` | `8069` | `8072` |
| Standby | `8118` | `8127` | `8069` | `8072` |

Nginx proxies to the **host port**. Both containers run simultaneously on different host ports; only one is behind Nginx at a time.

---

## File Structure

```
nginx/
├── sites-available/
│   ├── odoo18-compose-primary   ← Nginx config for primary slot (8018/8027)
│   └── odoo18-compose-standby  ← Nginx config for standby slot (8118/8127)
├── setup.sh                    ← One-time setup (certbot + install configs)
├── switch.sh                   ← Switch active slot (primary ↔ standby)
├── resetup.sh                  ← Re-apply configs without certbot
└── shutdown.sh                 ← Remove all Odoo Nginx configs

/etc/nginx/
├── sites-available/
│   ├── odoo18-compose-primary  ← Installed by setup.sh
│   └── odoo18-compose-standby
└── sites-enabled/
    └── odoo18-zerodowntime     ← Symlink to active config
```

---

## Nginx Config Features

Both site configs (`odoo18-compose-primary` and `odoo18-compose-standby`) include:

**TLS / SSL**
- `TLSv1.2 TLSv1.3` only — no older protocols
- Modern cipher suite (ECDHE + CHACHA20)
- `ssl_session_cache shared:SSL:10m` — session reuse across workers
- `ssl_session_tickets off` — forward secrecy
- OCSP stapling (`ssl_stapling on`) — faster handshake, no CRL round-trip
- IPv6 support: `listen [::]:443 ssl http2`

**HTTP/2**
- Enabled on both IPv4 and IPv6 listeners (`listen 443 ssl http2`)

**Security Headers**
- `Strict-Transport-Security` with `preload` (2-year max-age)
- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`

**Proxy**
- `upstream keepalive 32` — reuse connections to Odoo (no per-request TCP overhead)
- `proxy_http_version 1.1` + `Connection ""` — required for upstream keepalive
- `proxy_next_upstream error timeout http_502 http_503 http_504` — automatic retry on transient errors
- Separate upstream blocks for web and longpolling

**WebSocket / Longpolling**
- `/websocket` — Odoo 18 bus (3600s read/send timeout)
- `/longpolling` — legacy bus path (720s timeout)
- Both use `proxy_buffering off` for real-time delivery

**Static Assets**
- `location ~* \.(js|css|png|...)$` — 7-day browser cache, `Cache-Control: public, immutable`
- `access_log off` — reduces log noise for static files

**Compression**
- `gzip on` with `gzip_vary on` (correct Vary header for CDN compatibility)
- `gzip_comp_level 5` — balanced CPU/ratio
- Covers: text, CSS, JS, JSON, XML, SVG, WOFF/WOFF2

**Certbot Renewal**
- `location /.well-known/acme-challenge/ { root /var/www/certbot; }` — webroot renewal without stopping Nginx

---

## Scripts

### setup.sh

Run **once** on a fresh server. Obtains the SSL certificate, installs Nginx configs, and activates primary as the default slot.

```bash
sudo bash /opt/zerodowntime/nginx/setup.sh
```

**What it does:**

1. Validates that `nginx` and `certbot` are installed
2. Checks DNS resolution for the domain (warns if unresolved)
3. Runs `certbot certonly --standalone` to obtain the certificate (skips if cert already exists)
4. Creates `/var/www/certbot` for future webroot renewals
5. Copies `odoo18-compose-primary` and `odoo18-compose-standby` to `/etc/nginx/sites-available/`
6. Creates symlink: `sites-enabled/odoo18-zerodowntime → odoo18-compose-primary`
7. Removes the default Nginx page
8. Validates config (`nginx -t`) and starts Nginx
9. Writes a sudoers file (`/etc/sudoers.d/odoo-nginx`) so the deploy user can reload Nginx without a password

> **Idempotent:** Safe to run again — certbot is skipped if the certificate already exists.

---

### switch.sh

Switches Nginx traffic between primary and standby. Called automatically by GitHub Actions during deployment.

```bash
sudo bash /opt/zerodowntime/nginx/switch.sh primary
sudo bash /opt/zerodowntime/nginx/switch.sh standby
```

**What it does:**

1. Validates the argument is `primary` or `standby`
2. Verifies the target config file exists in `sites-available/`
3. Detects and shows the currently active slot
4. Updates the symlink atomically
5. Runs `nginx -t` — aborts if the config is invalid
6. Runs `nginx -s reload` — graceful, no dropped connections
7. Prints the new active slot and port

**Example output:**
```
[INFO]  Current : primary (port 8018)
[INFO]  Target  : standby (port 8118)
[INFO]  Updating symlink...
[INFO]  Validating Nginx config...
[INFO]  Reloading Nginx...

[OK]    Active: STANDBY (port 8118)
```

---

### resetup.sh

Re-applies Nginx configs from the repo without running certbot. Use this to refresh configs after editing them, or to recover from a broken state.

```bash
sudo bash /opt/zerodowntime/nginx/resetup.sh
```

**What it does:**

1. Removes all known stale symlinks (including old `blue`/`green` naming)
2. Copies updated config files from the repo to `/etc/nginx/sites-available/`
3. Re-creates the symlink pointing to primary
4. Reloads or starts Nginx

> **Idempotent:** Safe to run multiple times.

---

### shutdown.sh

Removes all Odoo Nginx configuration from the server. Nginx keeps running and serves other sites.

```bash
# Interactive (asks for confirmation)
sudo bash /opt/zerodowntime/nginx/shutdown.sh

# Skip confirmation
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes

# Also delete log files
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes --purge-logs

# Restore the default Nginx welcome page
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes --restore-default
```

**Flags:**

| Flag | Description |
|---|---|
| `--yes` | Skip interactive confirmation prompt |
| `--purge-logs` | Delete `odoo-primary.*` and `odoo-standby.*` log files |
| `--restore-default` | Re-enable `/etc/nginx/sites-enabled/default` (Nginx welcome page) |

**What it removes:**

- `sites-enabled/odoo18-zerodowntime` (symlink)
- `sites-available/odoo18-compose-primary`
- `sites-available/odoo18-compose-standby`
- `/etc/sudoers.d/odoo-nginx` (if it exists)
- Log files (only with `--purge-logs`)

> Docker containers are NOT affected.

---

## SSL Certificate

SSL is managed by Certbot (Let's Encrypt). Certificates are stored at:

```
/etc/letsencrypt/live/erp.zerodowntime.com/fullchain.pem
/etc/letsencrypt/live/erp.zerodowntime.com/privkey.pem
/etc/letsencrypt/live/erp.zerodowntime.com/chain.pem
```

**First-time issuance** is handled by `setup.sh` automatically.

**Auto-renewal** is managed by the Certbot systemd timer installed with the `certbot` package:

```bash
# Verify the timer is active
sudo systemctl status certbot.timer

# Test renewal (dry run)
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew
```

After renewal, Nginx does not need to be restarted — it reads the certificate files on each TLS handshake.

---

## Sudoers Setup

`setup.sh` automatically writes `/etc/sudoers.d/odoo-nginx` to allow the deploy user to run Nginx commands without a password (required for GitHub Actions SSH deploy):

```
ubuntu ALL=(ALL) NOPASSWD: /usr/sbin/nginx
ubuntu ALL=(ALL) NOPASSWD: /usr/bin/ln
ubuntu ALL=(ALL) NOPASSWD: /opt/zerodowntime/nginx/switch.sh
ubuntu ALL=(ALL) NOPASSWD: /opt/zerodowntime/nginx/shutdown.sh
```

To configure manually (replace `ubuntu` with your SSH username):

```bash
echo "ubuntu ALL=(ALL) NOPASSWD: /usr/sbin/nginx" | sudo tee /etc/sudoers.d/odoo-nginx
echo "ubuntu ALL=(ALL) NOPASSWD: /usr/bin/ln"     | sudo tee -a /etc/sudoers.d/odoo-nginx
sudo chmod 440 /etc/sudoers.d/odoo-nginx
```

---

## Commands Reference

```bash
# --- Setup & Recovery ---

# One-time setup (fresh server)
sudo bash /opt/zerodowntime/nginx/setup.sh

# Re-apply configs without certbot (idempotent)
sudo bash /opt/zerodowntime/nginx/resetup.sh

# Remove all Odoo nginx configs
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes

# Remove configs + delete log files
sudo bash /opt/zerodowntime/nginx/shutdown.sh --yes --purge-logs

# --- Traffic Switching ---

# Switch to primary
sudo bash /opt/zerodowntime/nginx/switch.sh primary

# Switch to standby
sudo bash /opt/zerodowntime/nginx/switch.sh standby

# Check which config is active
readlink /etc/nginx/sites-enabled/odoo18-zerodowntime

# --- Nginx Operations ---

# Test config syntax
sudo nginx -t

# Graceful reload (no downtime)
sudo nginx -s reload

# Status
sudo systemctl status nginx

# --- Logs ---

sudo tail -f /var/log/nginx/odoo-primary.access.log
sudo tail -f /var/log/nginx/odoo-primary.error.log
sudo tail -f /var/log/nginx/odoo-standby.access.log
sudo tail -f /var/log/nginx/odoo-standby.error.log

# --- SSL ---

# Check certificate expiry
sudo certbot certificates

# Test renewal (dry run)
sudo certbot renew --dry-run
```
