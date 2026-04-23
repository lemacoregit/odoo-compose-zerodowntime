# Nginx Blue-Green Configuration

> Nginx reverse proxy setup for Odoo 18 Blue-Green deployment with zero-downtime traffic switching via symlinks.

---

## Table of Contents

- [Overview](#overview)
- [How Traffic Switching Works](#how-traffic-switching-works)
- [Port Mapping](#port-mapping)
- [File Structure](#file-structure)
- [Config Files](#config-files)
  - [odoo18-compose-blue](#odoo18-compose-blue)
  - [odoo18-compose-green](#odoo18-compose-green)
- [Scripts](#scripts)
  - [setup.sh](#setupsh)
  - [switch.sh](#switchsh)
- [SSL Certificate](#ssl-certificate)
- [Commands Reference](#commands-reference)

---

## Overview

Nginx acts as the reverse proxy in front of the Blue-Green Odoo containers. Traffic switching between blue and green is done by updating a **symlink** in `sites-enabled/` and reloading Nginx — no downtime, no port changes for end users.

```
User Browser
     │ HTTPS :443
     ▼
  Nginx
     │
     │ sites-enabled/odoo18-zerodowntime  (symlink)
     │         │
     │    points to either:
     │         │
     ├── odoo18-compose-blue  → proxy_pass 127.0.0.1:8518
     └── odoo18-compose-green → proxy_pass 127.0.0.1:8618
```

---

## How Traffic Switching Works

Nginx reads its active config from `sites-enabled/odoo18-zerodowntime`, which is a symlink:

```bash
# When blue is active:
/etc/nginx/sites-enabled/odoo18-zerodowntime → /etc/nginx/sites-available/odoo18-compose-blue

# When green is active:
/etc/nginx/sites-enabled/odoo18-zerodowntime → /etc/nginx/sites-available/odoo18-compose-green
```

To switch, update the symlink and reload Nginx:

```bash
# Switch to green
sudo ln -sf /etc/nginx/sites-available/odoo18-compose-green /etc/nginx/sites-enabled/odoo18-zerodowntime
sudo nginx -s reload

# Switch to blue
sudo ln -sf /etc/nginx/sites-available/odoo18-compose-blue /etc/nginx/sites-enabled/odoo18-zerodowntime
sudo nginx -s reload
```

`nginx -s reload` applies the new config gracefully — active connections are not dropped.

---

## Port Mapping

| Environment | Odoo Web (host) | Longpolling (host) | Container Web | Container Longpoll |
|---|---|---|---|---|
| Blue | `8518` | `8572` | `8069` | `8072` |
| Green | `8618` | `8672` | `8069` | `8072` |

Nginx proxies to the **host port**. The containers internally always use `8069` (web) and `8072` (longpolling), mapped to different host ports to avoid conflicts when both are running simultaneously.

---

## File Structure

```
/etc/nginx/
├── sites-available/
│   ├── odoo18-compose-blue               ← Proxy config for blue (port 8518/8572)
│   └── odoo18-compose-green              ← Proxy config for green (port 8618/8672)
└── sites-enabled/
    └── odoo                    ← Symlink to active config (blue or green)

/opt/lemacore/nginx-bluegreen/
├── sites-available/
│   ├── odoo18-compose-blue               ← Source config files (copy to /etc/nginx)
│   └── odoo18-compose-green
├── setup.sh                    ← One-time setup script
└── switch.sh                   ← Traffic switch script
```

---

## Config Files

### odoo18-compose-blue

Proxies traffic to the Blue container (`127.0.0.1:8518` for web, `127.0.0.1:8572` for longpolling).

**Key sections:**

```nginx
upstream odoo_blue {
    server 127.0.0.1:8518;
}

upstream odoo_blue_longpolling {
    server 127.0.0.1:8572;
}
```

```nginx
# Longpolling — must be before the root location block
location /longpolling {
    proxy_pass http://odoo_blue_longpolling;
    ...
}

# Main application
location / {
    proxy_pass http://odoo_blue;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout    720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout    720s;
    ...
}

# Static assets — cached aggressively
location ~* \.(js|css|png|jpg|jpeg|gif|ico|woff|woff2|ttf|svg)$ {
    proxy_pass http://odoo_blue;
    expires 864000;
    add_header Cache-Control "public, immutable";
}
```

**Other settings:**
- `client_max_body_size 100m` — allows large file uploads
- `gzip on` — compresses responses for JS, CSS, JSON
- `ssl_protocols TLSv1.2 TLSv1.3` — modern TLS only
- Log file: `/var/log/nginx/odoo18-compose-blue.access.log`

---

### odoo18-compose-green

Identical structure to `odoo18-compose-blue`, but targets the Green container:

```nginx
upstream odoo_green {
    server 127.0.0.1:8618;      # ← different port
}

upstream odoo_green_longpolling {
    server 127.0.0.1:8672;      # ← different port
}
```

Log file: `/var/log/nginx/odoo18-compose-green.access.log`

> Both config files use the same `server_name zerodowntime.lemacore.com`. Only one is active at a time via the symlink, so there is no conflict.

---

## Scripts

### setup.sh

Run **once** on the server to obtain the SSL certificate, install Nginx configs, and set blue as the default active environment.

```bash
sudo bash /opt/lemacore/nginx-bluegreen/setup.sh
```

**What it does:**

1. Stops Nginx so certbot can bind port 80
2. Runs `certbot certonly --standalone -d zerodowntime.lemacore.com` to obtain the SSL certificate
3. Copies `odoo18-compose-blue` and `odoo18-compose-green` to `/etc/nginx/sites-available/`
4. Creates symlink: `sites-enabled/odoo18-zerodowntime → sites-available/odoo18-compose-blue`
5. Removes `/etc/nginx/sites-enabled/default` (prevents conflicts)
6. Runs `nginx -t` to validate
7. Starts Nginx via `systemctl start nginx`

> Requires `certbot` to be installed: `sudo apt install certbot`

---

### switch.sh

Switches traffic between blue and green. Called automatically by GitHub Actions during deployment, or manually when needed.

```bash
# Usage
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh [blue|green]

# Examples
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh green
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh blue
```

**What it does:**

1. Validates argument is `blue` or `green`
2. Updates symlink: `sites-enabled/odoo18-zerodowntime → sites-available/odoo18-compose-{target}`
3. Runs `nginx -t` — aborts if config is invalid
4. Runs `nginx -s reload` — graceful reload, no dropped connections
5. Prints which port is now active

**Example output:**
```
🔀 Switching Nginx → green...
🧪 Testing config...
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
🔄 Reloading Nginx...
✅ Active: GREEN (port 8618)
```

---

## SSL Certificate

SSL is managed by Certbot (Let's Encrypt). The certificate is referenced in both `odoo18-compose-blue` and `odoo18-compose-green`:

```nginx
ssl_certificate     /etc/letsencrypt/live/zerodowntime.lemacore.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/zerodowntime.lemacore.com/privkey.pem;
```

**Issue certificate (first time):**

`setup.sh` handles this automatically using `certbot --standalone`. To run it manually:

```bash
sudo systemctl stop nginx
sudo certbot certonly --standalone --non-interactive --agree-tos \
  --email aldi.saputra@mazuta.id \
  -d zerodowntime.lemacore.com
sudo systemctl start nginx
```

**Auto-renewal** is handled by the Certbot systemd timer (installed automatically). Verify it is active:
```bash
sudo systemctl status certbot.timer
```

**Manual renewal:**
```bash
sudo certbot renew --dry-run   # Test only
sudo certbot renew             # Actually renew
```

---

## Commands Reference

```bash
# Test Nginx configuration
sudo nginx -t

# Reload Nginx (graceful, no downtime)
sudo nginx -s reload

# Full restart (avoid in production)
sudo systemctl restart nginx

# Check which config is active
ls -la /etc/nginx/sites-enabled/odoo18-zerodowntime   # symlink name

# View access logs
sudo tail -f /var/log/nginx/odoo18-compose-blue.access.log
sudo tail -f /var/log/nginx/odoo18-compose-green.access.log

# View error logs
sudo tail -f /var/log/nginx/odoo18-compose-blue.error.log
sudo tail -f /var/log/nginx/odoo18-compose-green.error.log

# Manual switch to green
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh green

# Manual switch to blue
sudo bash /opt/lemacore/nginx-bluegreen/switch.sh blue

# Check SSL certificate expiry
sudo certbot certificates
```
