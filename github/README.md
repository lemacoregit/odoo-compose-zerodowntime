# CI/CD Pipeline

> GitHub Actions workflow for automated Odoo 18 zero-downtime deployment: primary/standby slot switching, module auto-detection, XML-RPC upgrade, rollback, and email notification.

---

## Table of Contents

- [Overview](#overview)
- [Workflow File](#workflow-file)
- [Jobs](#jobs)
  - [detect-changes](#detect-changes)
  - [deploy](#deploy)
  - [rollback](#rollback)
  - [notify](#notify)
  - [no-changes](#no-changes)
- [GitHub Secrets](#github-secrets)
- [Module Auto-Detection](#module-auto-detection)
- [Force Upgrade](#force-upgrade)
- [Deploy Logic](#deploy-logic)
- [upgrade_modules.py](#upgrade_modulespy)
- [Email Notification](#email-notification)
- [Triggers](#triggers)

---

## Overview

The pipeline runs automatically on every push to `main`. It detects which Odoo modules changed, deploys to the standby container using the primary/standby strategy, validates health before switching Nginx, upgrades only the changed modules, and sends an email with the result.

```
push → main
         │
         ▼
  ┌──────────────┐     no changes
  │detect-changes├──────────────────▶ no-changes (skip)
  └──────┬───────┘
         │ has changes
         ▼
  ┌──────────────┐
  │    deploy    │
  │              │
  │ 1. Pull code │
  │ 2. Start slot│ ── fail ──▶ abort (active keeps running)
  │ 3. Health ✓  │
  │ 4. Switch    │
  │ 5. Upgrade   │
  └──────┬───────┘
         │ always
         ▼
  ┌──────────────┐
  │    notify    │ → email (success / failed)
  └──────────────┘

Manual rollback:
  workflow_dispatch (action=rollback)
         │
         ▼
  ┌──────────────┐
  │   rollback   │ → switch Nginx back to previous slot
  └──────────────┘
```

---

## Workflow File

Location in repo: `github/deploy.yml`
Place on GitHub at: `.github/workflows/deploy.yml`

**Triggers:**

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      force_modules:  # comma-separated module names, optional
      action:         # "deploy" (default) or "rollback"
```

**Concurrency:**

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false
```

Queues concurrent runs instead of cancelling — prevents race conditions during deploy.

---

## Jobs

### detect-changes

Compares the last two commits to find which Odoo modules were modified.

**Logic:**

1. `git diff --name-only HEAD~1 HEAD` to list changed files
2. For each changed file, checks parent directory (up to 2 levels deep) for `__manifest__.py`
3. Collects unique module names as comma-separated output
4. If `force_modules` is provided, skips detection entirely

**Outputs:**

| Output | Type | Description |
|---|---|---|
| `changed_modules` | string | Comma-separated list of changed module names |
| `has_changes` | boolean | `true` if any modules detected |

---

### deploy

Runs only when `has_changes == true`. Connects to the server via SSH and performs zero-downtime deployment.

**Steps:**

| Step | Description |
|---|---|
| Setup SSH | Write `SSH_PRIVATE_KEY` to `~/.ssh/deploy_key`, add server fingerprint via `ssh-keyscan` |
| Pull latest code | SSH: `git reset --hard origin/main` in the addons directory |
| Zero-Downtime Deploy | SSH: detect active slot, start standby, health check, switch Nginx, stop old |
| Verify public endpoint | Poll `ODOO_URL/web/health` up to 60s after Nginx switch |
| Upgrade changed modules | Run `github/script/upgrade_modules.py` via XML-RPC from the runner |
| Cleanup SSH key | Always runs — removes `~/.ssh/deploy_key` |

**Timeout:** 20 minutes total.

---

### rollback

Manual trigger only — run via `workflow_dispatch` with `action = rollback`.

Reads the current Nginx symlink to determine the active slot, then starts and switches to the **other** slot. Does not upgrade any modules.

**Timeout:** 10 minutes.

---

### notify

Always runs after `deploy` (success or failure) when there were module changes. Sends an HTML email.

**Email contains:**
- Deploy status (SUCCESS / FAILED) with color indicator
- Branch name and short commit hash
- List of upgraded modules
- Triggered by (GitHub actor)
- Link to the workflow run

---

### no-changes

Runs only when `has_changes == false`. Prints a message and exits — no deployment.

---

## GitHub Secrets

Go to **Repository → Settings → Secrets and variables → Actions → New repository secret**.

**Server Access:**

| Secret | Description | Example |
|---|---|---|
| `SSH_PRIVATE_KEY` | OpenSSH private key for server access | `-----BEGIN OPENSSH PRIVATE KEY-----...` |
| `SSH_HOST` | Server IP or hostname | `103.x.x.x` |
| `SSH_USER` | SSH login username | `ubuntu` |

**Paths on Server:**

| Secret | Description | Example |
|---|---|---|
| `ODOO_ADDONS_PATH` | Absolute path to the custom addons git repo | `/opt/zerodowntime/docker/addons/custom` |
| `COMPOSE_PROJECT_PATH` | Absolute path to the project root (parent of `docker/`) | `/opt/zerodowntime` |
| `NGINX_SWITCH_SCRIPT_PATH` | Absolute path to `switch.sh` | `/opt/zerodowntime/nginx/switch.sh` |

**Odoo Connection:**

| Secret | Description | Example |
|---|---|---|
| `ODOO_URL` | Public Odoo URL (health check and XML-RPC) | `https://erp.zerodowntime.com` |
| `ODOO_DB` | Odoo database name | `odoo` |
| `ODOO_ADMIN_USER` | Odoo admin username | `admin` |
| `ODOO_ADMIN_PASSWORD` | Odoo admin password | `your_admin_password` |

**Email Notification:**

| Secret | Description | Example |
|---|---|---|
| `EMAIL_RECIPIENTS` | Comma-separated recipients | `dev@zerodowntime.com,ops@zerodowntime.com` |
| `SMTP_SERVER` | SMTP hostname | `smtp.gmail.com` |
| `SMTP_PORT` | SMTP port (`587` STARTTLS / `465` SSL) | `587` |
| `SMTP_USER` | SMTP login username | `noreply@zerodowntime.com` |
| `SMTP_PASSWORD` | SMTP password or App Password | `your_smtp_password` |
| `EMAIL_FROM` | Sender display name and address | `Odoo CI/CD <noreply@zerodowntime.com>` |

> `UPGRADE_SCRIPT_PATH` is no longer needed — the script now runs from the checked-out repo on the GitHub runner.

---

## Module Auto-Detection

Changed modules are detected by diffing the last two commits:

```bash
git diff --name-only HEAD~1 HEAD
```

A directory is treated as an Odoo module if it contains `__manifest__.py` at its root. The check looks up to two directory levels deep, so it works whether modules live at the repo root or in a subdirectory.

**Example:**

You push a commit that modifies:
```
sale_customization/models/sale_order.py
account_move_custom/__manifest__.py
README.md
```

Detection result:
```
changed_modules = sale_customization,account_move_custom
```

`README.md` is ignored — not inside a module directory.

---

## Force Upgrade

To upgrade specific modules without code changes:

1. Go to **Actions → Odoo CI/CD - Auto Deploy & Upgrade**
2. Click **Run workflow**
3. Enter module names in `force_modules`
4. Leave `action` as `deploy`
5. Click **Run workflow**

```
force_modules: sale_customization,account_move_custom
```

---

## Deploy Logic

The core deploy step runs over SSH:

```bash
# 1. Detect active slot
if docker ps | grep "odoo18-zerodowntime-primary"; then
  ACTIVE="primary"   NEXT="standby"   NEXT_PORT=8418
else
  ACTIVE="standby"   NEXT="primary"   NEXT_PORT=8318
fi

# 2. Pull latest image
docker compose $NEXT_COMPOSE pull $NEXT_SERVICE

# 3. Start next slot
docker compose $NEXT_COMPOSE up -d --force-recreate $NEXT_SERVICE

# 4. Health check (up to 94s)
for i in 1..12:
  HTTP = curl http://localhost:$NEXT_PORT/web/health
  if HTTP == 200: READY=true; break
  sleep 7

# 5a. Ready -> switch Nginx, stop old slot
if READY:
  bash switch.sh $NEXT
  docker compose $ACTIVE_COMPOSE stop $ACTIVE_SERVICE

# 5b. Not ready -> abort, active keeps serving traffic
else:
  docker compose $NEXT_COMPOSE stop $NEXT_SERVICE
  exit 1
```

**Failure behavior:** If the new container fails health checks, the pipeline aborts and the active container continues serving traffic. No Nginx switch occurs.

---

## upgrade_modules.py

Location in repo: `github/script/upgrade_modules.py`

Connects to Odoo's XML-RPC API and upgrades modules. Runs from the GitHub runner — does not require server access.

**Features:**
- Configurable socket timeout (`--timeout`, default 60s)
- Automatic retry with exponential backoff (3 attempts per XML-RPC call)
- Post-upgrade verification (re-checks module state after upgrade)
- Skips modules not yet installed (warning only, not a failure)

**Manual usage:**

```bash
# Via environment variables
export ODOO_URL=https://erp.zerodowntime.com
export ODOO_DB=odoo
export ODOO_ADMIN_USER=admin
export ODOO_ADMIN_PASSWORD=your_password
python3 github/script/upgrade_modules.py --modules sale_customization,account_move_custom

# Via arguments
python3 github/script/upgrade_modules.py \
  --url https://erp.zerodowntime.com \
  --db odoo \
  --user admin \
  --password your_password \
  --modules sale_customization,account_move_custom \
  --timeout 120
```

**Exit codes:**
- `0` — All modules upgraded and verified
- `1` — Connection error, authentication failed, or upgrade error

---

## Email Notification

The `notify` job sends an HTML email on every deploy (success or failure).

**Subject format:**
```
✅ [Odoo Deploy] SUCCESS — main (a1b2c3d)
❌ [Odoo Deploy] FAILED  — main (a1b2c3d)
```

**SMTP behavior:**
- Port `465` → `smtplib.SMTP_SSL` (implicit SSL)
- Port `587` → `smtplib.SMTP` with STARTTLS
- Sends individually per recipient (no CC/BCC)

**Gmail setup:**
1. **Google Account → Security → 2-Step Verification → App Passwords**
2. Generate a password for "Mail"
3. Use that password as `SMTP_PASSWORD`
4. Use `smtp.gmail.com` and port `587`

---

## Triggers

| Event | Behavior |
|---|---|
| Push to `main` | Auto-detect modules, full deploy + upgrade |
| `workflow_dispatch` with `force_modules` | Skip detection, deploy + upgrade specified modules |
| `workflow_dispatch` with `action=rollback` | Switch Nginx back to previous slot, no module upgrade |
| No Odoo modules changed in push | Skip deploy, print info message |
