#!/usr/bin/env bash
# Re-run Nginx config setup — safe to run multiple times.
# Use this to refresh config files after editing them in the repo,
# or to recover from a broken Nginx state.
#
# Does NOT request a new SSL certificate (certbot is skipped if cert exists).
# Usage: sudo bash nginx/resetup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
SYMLINK_NAME="odoo18-zerodowntime"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root (sudo bash resetup.sh)"
}

# ---------------------------------------------------------------------------
# Trap — ensure Nginx is running on any failure
# ---------------------------------------------------------------------------

trap 'echo; echo "[WARN]  Script exited — ensuring Nginx is running..."; systemctl start nginx 2>/dev/null || true' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_root

[[ -f "${SCRIPT_DIR}/sites-available/odoo18-compose-primary" ]]  || die "Missing: nginx/sites-available/odoo18-compose-primary"
[[ -f "${SCRIPT_DIR}/sites-available/odoo18-compose-standby" ]] || die "Missing: nginx/sites-available/odoo18-compose-standby"

# ---------------------------------------------------------------------------
# Step 1: Clean up all known stale symlinks
# ---------------------------------------------------------------------------

info "Removing stale symlinks from ${SITES_ENABLED}..."
for link in \
    default \
    odoo \
    "${SYMLINK_NAME}" \
    odoo18-compose-primary \
    odoo18-compose-standby \
    odoo18-compose-blue \
    odoo18-compose-green; do
    rm -f "${SITES_ENABLED}/${link}"
done
success "Stale symlinks removed."

# ---------------------------------------------------------------------------
# Step 2: Refresh config files from repo
# ---------------------------------------------------------------------------

info "Copying updated config files..."
cp "${SCRIPT_DIR}/sites-available/odoo18-compose-primary"  "${SITES_AVAILABLE}/odoo18-compose-primary"
cp "${SCRIPT_DIR}/sites-available/odoo18-compose-standby" "${SITES_AVAILABLE}/odoo18-compose-standby"
success "Config files updated."

# ---------------------------------------------------------------------------
# Step 3: Activate primary as default
# ---------------------------------------------------------------------------

info "Activating primary as default slot..."
ln -sf "${SITES_AVAILABLE}/odoo18-compose-primary" "${SITES_ENABLED}/${SYMLINK_NAME}"
success "Symlink: ${SITES_ENABLED}/${SYMLINK_NAME} -> odoo18-compose-primary"

# ---------------------------------------------------------------------------
# Step 4: Validate and reload/start Nginx
# ---------------------------------------------------------------------------

info "Validating Nginx config..."
nginx -t

if systemctl is-active --quiet nginx; then
    info "Reloading Nginx..."
    nginx -s reload
    success "Nginx reloaded."
else
    info "Starting Nginx..."
    systemctl start nginx
    success "Nginx started."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
success "Re-setup complete!"
echo
echo "  Active slot : PRIMARY (port 8018)"
echo "  Symlink     : ${SITES_ENABLED}/${SYMLINK_NAME}"
echo
echo "  Switch to standby : sudo bash ${SCRIPT_DIR}/switch.sh standby"
echo "  Switch to primary : sudo bash ${SCRIPT_DIR}/switch.sh primary"
