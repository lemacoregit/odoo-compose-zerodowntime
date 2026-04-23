#!/bin/bash
# Switch Nginx between blue and green
# Usage: sudo bash switch.sh blue | sudo bash switch.sh green

set -e

TARGET=$1
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"

if [[ "$TARGET" != "blue" && "$TARGET" != "green" ]]; then
    echo "Usage: sudo bash switch.sh [blue|green]"
    exit 1
fi

echo "🔀 Switching Nginx → $TARGET..."
sudo ln -sf $SITES_AVAILABLE/odoo18-compose-$TARGET $SITES_ENABLED/odoo18-zerodowntime

echo "🧪 Testing config..."
sudo nginx -t

echo "🔄 Reloading Nginx..."
sudo nginx -s reload

echo "✅ Active: $(echo $TARGET | tr '[:lower:]' '[:upper:]') (port $([ "$TARGET" = "blue" ] && echo "8518" || echo "8618"))"
