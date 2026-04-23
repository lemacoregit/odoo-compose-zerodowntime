#!/bin/bash
# Re-setup script — safe to run multiple times.
# Cleans up stale symlinks and duplicate configs before re-applying setup.

set -e

DOMAIN="zerodowntime.lemacore.com"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

# Always attempt to start Nginx on exit, even if the script fails midway.
trap 'echo "⚠️  Script exited — ensuring Nginx is running..."; sudo systemctl start nginx 2>/dev/null || true' ERR

echo "🧹 Cleaning up stale symlinks in sites-enabled..."
sudo rm -f \
  $SITES_ENABLED/default \
  $SITES_ENABLED/odoo \
  $SITES_ENABLED/odoo18-compose-blue \
  $SITES_ENABLED/odoo18-compose-green \
  $SITES_ENABLED/odoo18-zerodowntime

echo "📂 Copying config files..."
sudo cp sites-available/odoo18-compose-blue  $SITES_AVAILABLE/odoo18-compose-blue
sudo cp sites-available/odoo18-compose-green $SITES_AVAILABLE/odoo18-compose-green

echo "🔗 Activating green as default..."
sudo ln -sf $SITES_AVAILABLE/odoo18-compose-green $SITES_ENABLED/odoo18-zerodowntime

echo "🧪 Testing Nginx config..."
sudo nginx -t

if systemctl is-active --quiet nginx; then
  echo "🔄 Reloading Nginx..."
  sudo nginx -s reload
else
  echo "🚀 Starting Nginx..."
  sudo systemctl start nginx
fi

echo "✅ Done! Active: BLUE (port 8518)"
echo ""
echo "To switch manually:"
echo "  → Green: sudo bash $(dirname "$0")/switch.sh green"
echo "  → Blue:  sudo bash $(dirname "$0")/switch.sh blue"
