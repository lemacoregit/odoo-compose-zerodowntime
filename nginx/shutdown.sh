#!/usr/bin/env bash
# Remove Odoo Nginx configuration from this server.
# Deletes the active symlink, config files from sites-available,
# and optionally log files. Nginx keeps running (serving other sites).
#
# Usage:
#   sudo bash nginx/shutdown.sh              # interactive confirmation
#   sudo bash nginx/shutdown.sh --yes        # skip confirmation
#   sudo bash nginx/shutdown.sh --yes --purge-logs     # also delete log files
#   sudo bash nginx/shutdown.sh --yes --restore-default # re-enable nginx default page

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
SYMLINK_NAME="odoo18-zerodowntime"
LOG_DIR="/var/log/nginx"
SUDOERS_FILE="/etc/sudoers.d/odoo-nginx"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

OPT_YES=false
OPT_PURGE_LOGS=false
OPT_RESTORE_DEFAULT=false

for arg in "$@"; do
    case "$arg" in
        --yes)             OPT_YES=true ;;
        --purge-logs)      OPT_PURGE_LOGS=true ;;
        --restore-default) OPT_RESTORE_DEFAULT=true ;;
        --help|-h)
            echo "Usage: sudo bash shutdown.sh [--yes] [--purge-logs] [--restore-default]"
            echo
            echo "  --yes               Skip confirmation prompt"
            echo "  --purge-logs        Delete Odoo Nginx log files"
            echo "  --restore-default   Re-enable the default Nginx welcome page"
            exit 0
            ;;
        *) echo "[ERROR] Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root (sudo bash shutdown.sh)"
}

removed() {
    if [[ -e "$1" || -L "$1" ]]; then
        rm -f "$1"
        success "Removed: $1"
    else
        info "Not found (skipped): $1"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_root

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------

ACTIVE_SLOT="(none)"
if [[ -L "${SITES_ENABLED}/${SYMLINK_NAME}" ]]; then
    ACTIVE_LINK=$(readlink "${SITES_ENABLED}/${SYMLINK_NAME}" 2>/dev/null || echo "")
    [[ "${ACTIVE_LINK}" == *primary* ]] && ACTIVE_SLOT="primary"
    [[ "${ACTIVE_LINK}" == *standby* ]] && ACTIVE_SLOT="standby"
fi

echo
echo "  This will remove the following from this server:"
echo "    - Symlink : ${SITES_ENABLED}/${SYMLINK_NAME}  (active: ${ACTIVE_SLOT})"
echo "    - Config  : ${SITES_AVAILABLE}/odoo18-compose-primary"
echo "    - Config  : ${SITES_AVAILABLE}/odoo18-compose-standby"
[[ "${OPT_PURGE_LOGS}" == true ]] && echo "    - Logs    : ${LOG_DIR}/odoo-primary.* ${LOG_DIR}/odoo-standby.*"
[[ "${OPT_PURGE_LOGS}" == false ]] && echo "    - Logs    : KEPT (use --purge-logs to delete)"
[[ -f "${SUDOERS_FILE}" ]] && echo "    - Sudoers : ${SUDOERS_FILE}"
echo "  Nginx will keep running and serve other sites."
echo

if [[ "${OPT_YES}" != true ]]; then
    read -r -p "  Proceed? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Remove symlink
# ---------------------------------------------------------------------------

info "Removing active symlink..."
removed "${SITES_ENABLED}/${SYMLINK_NAME}"

# ---------------------------------------------------------------------------
# Remove config files from sites-available
# ---------------------------------------------------------------------------

info "Removing Nginx config files..."
removed "${SITES_AVAILABLE}/odoo18-compose-primary"
removed "${SITES_AVAILABLE}/odoo18-compose-standby"

# ---------------------------------------------------------------------------
# Remove log files (optional)
# ---------------------------------------------------------------------------

if [[ "${OPT_PURGE_LOGS}" == true ]]; then
    info "Removing log files..."
    for f in \
        "${LOG_DIR}/odoo-primary.access.log" \
        "${LOG_DIR}/odoo-primary.error.log" \
        "${LOG_DIR}/odoo-standby.access.log" \
        "${LOG_DIR}/odoo-standby.error.log"; do
        removed "$f"
    done
fi

# ---------------------------------------------------------------------------
# Remove sudoers file (optional — only if created by setup.sh)
# ---------------------------------------------------------------------------

if [[ -f "${SUDOERS_FILE}" ]]; then
    info "Removing sudoers file..."
    removed "${SUDOERS_FILE}"
fi

# ---------------------------------------------------------------------------
# Restore default Nginx page (optional)
# ---------------------------------------------------------------------------

if [[ "${OPT_RESTORE_DEFAULT}" == true ]]; then
    DEFAULT_SRC="/etc/nginx/sites-available/default"
    DEFAULT_LINK="${SITES_ENABLED}/default"
    if [[ -f "${DEFAULT_SRC}" && ! -L "${DEFAULT_LINK}" ]]; then
        info "Restoring Nginx default site..."
        ln -sf "${DEFAULT_SRC}" "${DEFAULT_LINK}"
        success "Default site re-enabled."
    else
        warn "Default site source not found or already enabled — skipping."
    fi
fi

# ---------------------------------------------------------------------------
# Reload Nginx so it stops serving the removed configs
# ---------------------------------------------------------------------------

info "Reloading Nginx..."
if nginx -t 2>/dev/null; then
    nginx -s reload
    success "Nginx reloaded."
else
    warn "Nginx config test failed after removal — check remaining configs."
    warn "Run: sudo nginx -t"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
success "Shutdown complete."
echo
echo "  Nginx is still running — Odoo configs removed."
echo "  Docker containers are NOT affected by this script."
echo
echo "  To restore Odoo Nginx configs, run:"
echo "    sudo bash ${SCRIPT_DIR}/setup.sh   (fresh setup)"
echo "    sudo bash ${SCRIPT_DIR}/resetup.sh (re-apply without certbot)"
