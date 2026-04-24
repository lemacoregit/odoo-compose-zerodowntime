#!/usr/bin/env bash
# Switch Nginx traffic between primary and standby slots.
# Called by GitHub Actions during deployment or run manually.
#
# Usage:
#   sudo bash switch.sh primary
#   sudo bash switch.sh standby

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
SYMLINK_NAME="odoo18-zerodowntime"

declare -A SLOT_PORT=([primary]="8318" [standby]="8418")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validate input
# ---------------------------------------------------------------------------

TARGET="${1:-}"
[[ "$TARGET" == "primary" || "$TARGET" == "standby" ]] \
    || die "Usage: sudo bash switch.sh [primary|standby]"

CONFIG_FILE="${SITES_AVAILABLE}/odoo18-compose-${TARGET}"
[[ -f "${CONFIG_FILE}" ]] \
    || die "Config file not found: ${CONFIG_FILE} — run setup.sh first"

# ---------------------------------------------------------------------------
# Detect current active slot
# ---------------------------------------------------------------------------

CURRENT="(none)"
if [[ -L "${SITES_ENABLED}/${SYMLINK_NAME}" ]]; then
    CURRENT_LINK=$(readlink "${SITES_ENABLED}/${SYMLINK_NAME}")
    case "${CURRENT_LINK}" in
        *primary*) CURRENT="primary (port ${SLOT_PORT[primary]})" ;;
        *standby*) CURRENT="standby (port ${SLOT_PORT[standby]})" ;;
        *)         CURRENT="${CURRENT_LINK}" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Switch
# ---------------------------------------------------------------------------

info "Current : ${CURRENT}"
info "Target  : ${TARGET} (port ${SLOT_PORT[$TARGET]})"

info "Updating symlink..."
sudo ln -sf "${CONFIG_FILE}" "${SITES_ENABLED}/${SYMLINK_NAME}"

info "Validating Nginx config..."
sudo nginx -t

info "Reloading Nginx..."
sudo nginx -s reload

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo "[OK]    Active: ${TARGET^^} (port ${SLOT_PORT[$TARGET]})"
