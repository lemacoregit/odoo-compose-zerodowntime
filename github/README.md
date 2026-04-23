# CI/CD Pipeline

> GitHub Actions workflow for automated Odoo 18 deployment with Blue-Green strategy, module auto-detection, XML-RPC upgrade, and email notification.

---

## Table of Contents

- [Overview](#overview)
- [Workflow File](#workflow-file)
- [Jobs](#jobs)
  - [detect-changes](#detect-changes)
  - [deploy](#deploy)
  - [notify](#notify)
  - [no-changes](#no-changes)
- [GitHub Secrets](#github-secrets)
- [Module Auto-Detection](#module-auto-detection)
- [Force Upgrade](#force-upgrade)
- [Blue-Green Deploy Step](#blue-green-deploy-step)
- [upgrade_modules.py](#upgrade_modulespy)
- [Email Notification](#email-notification)
- [Triggers](#triggers)

---

## Overview

The pipeline runs automatically on every push to the `18.0` branch. It detects which Odoo modules changed, deploys to the standby container using Blue-Green strategy, upgrades only the changed modules, and sends an email notification with the result.

```
push → 18.0 branch
         │
         ▼
  ┌──────────────┐     no changes
  │detect-changes├─────────────────▶ no-changes (skip deploy)
  └──────┬───────┘
         │ has changes
         ▼
  ┌──────────────┐
  │    deploy    │
  │              │
  │ 1. Pull code │
  │ 2. Blue-Green│ ── fail ──▶ abort (keep active container)
  │ 3. Health ✓  │
  │ 4. Upgrade   │
  └──────┬───────┘
         │ always
         ▼
  ┌──────────────┐
  │    notify    │ → email (success / failed)
  └──────────────┘
```

---

## Workflow File

Location: `.github/workflows/deploy.yml`

**Triggers:**
```yaml
on:
  push:
    branches:
      - 18.0
  workflow_dispatch:
    inputs:
      force_modules:
        description: "Force upgrade specific modules (comma-separated)"
        required: false
        default: ""
```

---

## Jobs

### detect-changes

Compares the last two commits to find which Odoo modules were modified.

**Logic:**
1. Run `git diff --name-only HEAD~1 HEAD` to list changed files
2. For each changed file, check if its parent directory contains `__manifest__.py`
3. Collect unique module names and output them as a comma-separated string
4. If `force_modules` is provided via `workflow_dispatch`, skip detection and use that value directly

**Outputs:**

| Output | Type | Description |
|---|---|---|
| `changed_modules` | string | Comma-separated list of changed module names |
| `has_changes` | boolean | `true` if any modules were detected, `false` otherwise |

---

### deploy

Runs only when `has_changes == true`. Connects to the server via SSH and performs the full Blue-Green deployment.

**Steps:**

| Step | Description |
|---|---|
| Checkout repository | Checks out code on the GitHub runner |
| Setup SSH key | Writes `SSH_PRIVATE_KEY` to `~/.ssh/id_rsa` and adds server to known_hosts |
| Pull latest code on server | SSH: `git reset --hard origin/18.0` in the addons directory |
| Blue-Green Deploy | SSH: detect active container, deploy standby, health check, switch Nginx, stop old |
| Wait for Odoo to be stable | Polls `ODOO_URL/web/health` up to 60s after Nginx switch |
| Upgrade changed modules | Runs `upgrade_modules.py` via XML-RPC |

---

### notify

Always runs after `deploy` (whether it succeeded or failed), as long as there were changes. Sends an HTML email using Python's `smtplib`.

**Email contains:**
- Deploy status (SUCCESS / FAILED) with color indicator
- Branch name and short commit hash
- List of upgraded modules
- Triggered by (GitHub actor)
- Link to the workflow run

---

### no-changes

Runs only when `has_changes == false`. Simply prints a message and exits — no deployment is performed.

---

## GitHub Secrets

Go to **Repository → Settings → Secrets and variables → Actions** and configure:

**Server Access:**

| Secret | Description | Example |
|---|---|---|
| `SSH_PRIVATE_KEY` | Private SSH key to access the server | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `SSH_HOST` | Server IP or hostname | `103.x.x.x` |
| `SSH_USER` | SSH login username | `ubuntu` |

**Paths on Server:**

| Secret | Description | Example |
|---|---|---|
| `ODOO_ADDONS_PATH` | Absolute path to the custom addons git repo | `/opt/lemacore/odoo/custom-addons` |
| `COMPOSE_PROJECT_PATH` | Absolute path to the docker compose directory | `/opt/lemacore` |
| `NGINX_SWITCH_SCRIPT_PATH` | Absolute path to `switch.sh` | `/opt/lemacore/nginx-bluegreen/switch.sh` |
| `UPGRADE_SCRIPT_PATH` | Absolute path to `upgrade_modules.py` | `/opt/lemacore/upgrade_modules.py` |

**Odoo Connection:**

| Secret | Description | Example |
|---|---|---|
| `ODOO_URL` | Public Odoo URL (used for health check and XML-RPC) | `https://erp.lemacore.com` |
| `ODOO_DB` | Odoo database name | `odoo` |
| `ODOO_ADMIN_USER` | Odoo admin username | `admin` |
| `ODOO_ADMIN_PASSWORD` | Odoo admin password | `your_admin_password` |

**Email Notification:**

| Secret | Description | Example |
|---|---|---|
| `EMAIL_RECIPIENTS` | Comma-separated list of recipients | `dev@lemacore.com,ops@lemacore.com` |
| `SMTP_SERVER` | SMTP hostname | `smtp.gmail.com` |
| `SMTP_PORT` | SMTP port (`587` = STARTTLS, `465` = SSL) | `587` |
| `SMTP_USER` | SMTP login username | `noreply@lemacore.com` |
| `SMTP_PASSWORD` | SMTP password or App Password | `your_smtp_password` |
| `EMAIL_FROM` | Sender name and email | `Odoo CI/CD <noreply@lemacore.com>` |

> **Removed:** `COMPOSE_SERVICE` is no longer needed and can be deleted from your secrets.

---

## Module Auto-Detection

The pipeline detects changed modules by diffing the last two commits:

```bash
git diff --name-only HEAD~1 HEAD
```

A directory is considered an Odoo module if and only if it contains `__manifest__.py` at the root level.

**Example scenario:**

You push a commit that modifies these files:
```
sale_customization/models/sale_order.py
sale_customization/views/sale_order_view.xml
account_move_custom/__manifest__.py
README.md
```

The pipeline will detect:
```
changed_modules = sale_customization,account_move_custom
```

`README.md` is ignored because it is not inside a module directory.

---

## Force Upgrade

To upgrade specific modules without pushing code changes, use the manual trigger:

1. Go to **Actions → Odoo CI/CD - Auto Deploy & Upgrade**
2. Click **Run workflow**
3. Enter module names in the `force_modules` field
4. Click **Run workflow**

```
force_modules: sale_customization,account_move_custom,stock_custom
```

This bypasses `git diff` entirely and runs the full deploy + upgrade pipeline for the specified modules.

---

## Blue-Green Deploy Step

This is the core of the deployment. It runs over SSH and performs the full switch atomically.

**Full logic:**

```bash
# 1. Detect which container is currently running
if docker ps | grep "odoo18-zerodowntime-blue"; then
  ACTIVE="blue"
  NEXT="green"
  NEXT_PORT=8118
else
  ACTIVE="green"
  NEXT="blue"
  NEXT_PORT=8018
fi

# 2. Pull latest image for standby
docker compose -f docker-$NEXT.yml pull odoo

# 3. Start standby container
docker compose -f docker-$NEXT.yml up -d --force-recreate odoo

# 4. Health check (max 90s)
for i in 1..12:
  HTTP = curl http://localhost:$NEXT_PORT/web/health
  if HTTP == 200: READY = true; break
  sleep 7

# 5a. If ready: switch Nginx, stop old container
if READY:
  bash switch.sh $NEXT
  docker compose -f docker-$ACTIVE.yml down

# 5b. If not ready: abort, rollback standby
else:
  docker compose -f docker-$NEXT.yml down
  exit 1   ← pipeline fails, active container untouched
```

**Failure behavior:** If the new container fails to pass health checks, the pipeline aborts with `exit 1` and the active container continues serving traffic. No traffic switch occurs.

---

## upgrade_modules.py

After a successful Blue-Green switch, the pipeline runs `upgrade_modules.py` on the GitHub runner via Python. It connects to Odoo's XML-RPC API and upgrades the changed modules.

**Manual usage:**

```bash
# Using environment variables
export ODOO_URL=https://erp.lemacore.com
export ODOO_DB=odoo
export ODOO_ADMIN_USER=admin
export ODOO_ADMIN_PASSWORD=your_password
python3 upgrade_modules.py --modules sale_customization,account_move_custom

# Using arguments directly
python3 upgrade_modules.py \
  --url https://erp.lemacore.com \
  --db odoo \
  --user admin \
  --password your_password \
  --modules sale_customization,account_move_custom
```

**Exit codes:**
- `0` — All modules upgraded successfully
- `1` — Connection failed, authentication failed, or upgrade error

**What happens if a module is not installed?**

The script prints a warning but does **not** fail. This handles the case where a new module is being added for the first time (it needs to be installed manually first via Odoo UI, then subsequent pushes will upgrade it).

---

## Email Notification

The notify job sends an HTML email regardless of the deploy outcome (success or failure).

**Email content:**

```
Subject: ✅ [Odoo Deploy] SUCCESS — 18.0 (a1b2c3d)
      or ❌ [Odoo Deploy] FAILED  — 18.0 (a1b2c3d)

Body:
  Branch:      18.0
  Commit:      a1b2c3d
  Modules:     sale_customization,account_move_custom
  Triggered by: your-github-username
  [View Workflow Details] → link to GitHub Actions run
```

**SMTP behavior:**
- Port `465` → uses `smtplib.SMTP_SSL` (implicit SSL)
- Port `587` → uses `smtplib.SMTP` with `STARTTLS`
- Sends individually per recipient (not CC/BCC) to avoid reply-all issues

**Gmail setup:**

If using Gmail as SMTP, generate an App Password:
1. Go to **Google Account → Security → 2-Step Verification → App Passwords**
2. Generate a password for "Mail"
3. Use that password as `SMTP_PASSWORD`
4. Use `smtp.gmail.com` as `SMTP_SERVER` and `587` as `SMTP_PORT`

---

## Triggers

| Event | Behavior |
|---|---|
| Push to `18.0` | Auto-detects changed modules, runs full pipeline |
| `workflow_dispatch` with `force_modules` empty | Same as push, runs auto-detection |
| `workflow_dispatch` with `force_modules` filled | Skips detection, upgrades specified modules |
| No Odoo modules changed in push | Skips deploy entirely, prints info message |