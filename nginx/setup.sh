#!/bin/bash
# Initial Nginx Blue-Green setup for zerodowntime.lemacore.com
# Run once on the server: sudo bash setup.sh

set -e

DOMAIN="zerodowntime.lemacore.com"
EMAIL="aldialputra@gmail.com"
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

# Always restart Nginx on failure so other sites are not left down.
trap 'echo "⚠️  Script failed — restarting Nginx to restore other sites..."; sudo systemctl start nginx 2>/dev/null || true' ERR

# Step 1: Stop Nginx so certbot --standalone can bind port 80
echo "⏹️  Stopping Nginx..."
sudo systemctl stop nginx

# Step 2: Obtain SSL certificate via certbot standalone
echo "🔐 Obtaining SSL certificate for $DOMAIN..."
sudo certbot certonly --standalone \
  --non-interactive \
  --agree-tos \
  --email "$EMAIL" \
  -d "$DOMAIN"

# Step 3: Copy SSL-ready Nginx config files
echo "📂 Copying config files..."
sudo cp sites-available/odoo18-compose-blue  $SITES_AVAILABLE/odoo18-compose-blue
sudo cp sites-available/odoo18-compose-green $SITES_AVAILABLE/odoo18-compose-green

# Step 4: Activate green as default, remove default site
echo "🔗 Activating green as default..."
sudo ln -sf $SITES_AVAILABLE/odoo18-compose-green $SITES_ENABLED/odoo18-zerodowntime
sudo rm -f $SITES_ENABLED/default

# Step 5: Test config then start Nginx
echo "🧪 Testing Nginx config..."
sudo nginx -t

echo "🚀 Starting Nginx..."
sudo systemctl start nginx

echo "✅ Done! Active: GREEN (port 8618)"
echo ""
echo "To switch manually:"
echo "  → Green: sudo bash /opt/lemacore/nginx-bluegreen/switch.sh green"
echo "  → Blue:  sudo bash /opt/lemacore/nginx-bluegreen/switch.sh blue"
