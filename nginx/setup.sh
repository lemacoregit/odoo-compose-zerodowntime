#!/usr/bin/env bash
# Initial Nginx + SSL setup for erp.zerodowntime.com
# Run once on a fresh server: sudo bash nginx/setup.sh
#
# What it does:
#   1. Validates environment (nginx, certbot installed; domain resolves)
#   2. Obtains a Let's Encrypt certificate via certbot --standalone
#   3. Installs the primary and standby Nginx configs
#   4. Activates primary as the default active slot
#   5. Creates /var/www/certbot for future webroot renewals
#   6. Configures sudoers so the deploy user can reload nginx without a password

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DOMAIN="erp.zerodowntime.com"
ADMIN_EMAIL="admin@zerodowntime.com"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
SYMLINK_NAME="odoo18-zerodowntime"
CERTBOT_WEBROOT="/var/www/certbot"
DEPLOY_USER="${SUDO_USER:-ubuntu}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root (sudo bash setup.sh)"
}

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is not installed. Run: sudo apt install $2"
}

check_domain_resolves() {
    info "Checking DNS for ${DOMAIN}..."
    if ! host "${DOMAIN}" &>/dev/null && ! getent hosts "${DOMAIN}" &>/dev/null; then
        warn "Cannot resolve ${DOMAIN} — make sure the DNS A record points to this server."
        warn "Certbot will fail if the domain does not resolve to this IP."
        read -r -p "Continue anyway? [y/N] " answer
        [[ "${answer,,}" == "y" ]] || exit 0
    else
        success "DNS for ${DOMAIN} resolved."
    fi
}

# ---------------------------------------------------------------------------
# Trap — restore Nginx on failure
# ---------------------------------------------------------------------------

trap 'echo; die "Setup failed — attempting to start Nginx to restore other sites..."; systemctl start nginx 2>/dev/null || true' ERR

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

require_root
require_cmd nginx  "nginx"
require_cmd certbot "certbot python3-certbot-nginx"

info "Checking Nginx config files..."
[[ -f "${SCRIPT_DIR}/sites-available/odoo18-compose-primary" ]]  || die "Missing: nginx/sites-available/odoo18-compose-primary"
[[ -f "${SCRIPT_DIR}/sites-available/odoo18-compose-standby" ]] || die "Missing: nginx/sites-available/odoo18-compose-standby"

# ---------------------------------------------------------------------------
# Step 1: Obtain SSL certificate
# ---------------------------------------------------------------------------

if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    success "SSL certificate for ${DOMAIN} already exists — skipping certbot."
else
    check_domain_resolves

    info "Stopping Nginx so certbot --standalone can bind port 80..."
    systemctl stop nginx

    info "Obtaining SSL certificate for ${DOMAIN}..."
    certbot certonly --standalone \
        --non-interactive \
        --agree-tos \
        --email "${ADMIN_EMAIL}" \
        -d "${DOMAIN}"

    success "Certificate obtained."
fi

# ---------------------------------------------------------------------------
# Step 2: Create certbot webroot directory for future renewals
# ---------------------------------------------------------------------------

mkdir -p "${CERTBOT_WEBROOT}"
success "Created ${CERTBOT_WEBROOT} for future webroot renewals."

# ---------------------------------------------------------------------------
# Step 3: Install Nginx config files
# ---------------------------------------------------------------------------

info "Installing Nginx config files..."
cp "${SCRIPT_DIR}/sites-available/odoo18-compose-primary"  "${SITES_AVAILABLE}/odoo18-compose-primary"
cp "${SCRIPT_DIR}/sites-available/odoo18-compose-standby" "${SITES_AVAILABLE}/odoo18-compose-standby"
success "Config files installed to ${SITES_AVAILABLE}/"

# ---------------------------------------------------------------------------
# Step 4: Activate primary as default, remove default site
# ---------------------------------------------------------------------------

info "Activating primary as the default slot..."
ln -sf "${SITES_AVAILABLE}/odoo18-compose-primary" "${SITES_ENABLED}/${SYMLINK_NAME}"
rm -f "${SITES_ENABLED}/default"
success "Symlink created: ${SITES_ENABLED}/${SYMLINK_NAME} -> odoo18-compose-primary"

# ---------------------------------------------------------------------------
# Step 5: Validate and start Nginx
# ---------------------------------------------------------------------------

info "Validating Nginx config..."
nginx -t

info "Starting Nginx..."
systemctl start nginx
success "Nginx started."

# ---------------------------------------------------------------------------
# Step 6: Configure sudoers for deploy user (nginx reload without password)
# ---------------------------------------------------------------------------

SUDOERS_FILE="/etc/sudoers.d/odoo-nginx"
if [[ ! -f "${SUDOERS_FILE}" ]]; then
    info "Writing sudoers entry for ${DEPLOY_USER}..."
    cat > "${SUDOERS_FILE}" <<EOF
# Allow the deploy user to reload/test Nginx and run switch.sh without a password
${DEPLOY_USER} ALL=(ALL) NOPASSWD: /usr/sbin/nginx
${DEPLOY_USER} ALL=(ALL) NOPASSWD: /usr/bin/ln
${DEPLOY_USER} ALL=(ALL) NOPASSWD: ${SCRIPT_DIR}/switch.sh
${DEPLOY_USER} ALL=(ALL) NOPASSWD: ${SCRIPT_DIR}/shutdown.sh
EOF
    chmod 440 "${SUDOERS_FILE}"
    success "Sudoers file written: ${SUDOERS_FILE}"
else
    info "Sudoers file already exists at ${SUDOERS_FILE} — skipping."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
success "Setup complete!"
echo
echo "  Active slot : PRIMARY (port 8318)"
echo "  Domain      : https://${DOMAIN}"
echo "  Symlink     : ${SITES_ENABLED}/${SYMLINK_NAME}"
echo
echo "Useful commands:"
echo "  Switch to standby : sudo bash ${SCRIPT_DIR}/switch.sh standby"
echo "  Switch to primary : sudo bash ${SCRIPT_DIR}/switch.sh primary"
echo "  Re-run setup      : sudo bash ${SCRIPT_DIR}/resetup.sh"
echo "  Remove nginx cfg  : sudo bash ${SCRIPT_DIR}/shutdown.sh"
echo "  Check SSL expiry  : sudo certbot certificates"
