#!/usr/bin/env bash
# QRKing: put the site on this server with HTTPS. Safe to run again (it updates the site).
# Usage (as root):  curl -fsSL https://raw.githubusercontent.com/darlingbo/qrking-site/main/setup.sh | bash
set -euo pipefail

DOMAIN="${DOMAIN:-144-202-58-251.sslip.io}"   # free name that points to this server; change when you buy a domain
WEBROOT="/var/www/qrking"
REPO="https://github.com/darlingbo/qrking-site.git"

say(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "1/6 Checking ports 80 and 443 are free (so we don't disturb other apps)"
if ss -tlnp | grep -E ':(80|443)\s' | grep -vq nginx; then
  ss -tlnp | grep -E ':(80|443)\s'
  echo "Another program is using port 80 or 443. Stopping so nothing breaks. Send this output to Claude."
  exit 1
fi

say "2/6 Installing nginx, git and certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx git certbot python3-certbot-nginx >/dev/null

say "3/6 Getting the site files"
if [ -d "$WEBROOT/.git" ]; then git -C "$WEBROOT" pull --ff-only; else rm -rf "$WEBROOT"; git clone --depth 1 "$REPO" "$WEBROOT"; fi

say "4/6 Setting up nginx for $DOMAIN"
cat > /etc/nginx/sites-available/qrking <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
    location ~ /\.git { deny all; }
    location = /setup.sh { deny all; }
    location / { try_files \$uri \$uri/ /index.html; }
    location = /index.html { add_header Cache-Control "no-cache"; }
    location = /sw.js { add_header Cache-Control "no-cache"; }
    gzip on;
    gzip_types text/css application/javascript application/json application/manifest+json image/svg+xml;
}
EOF
ln -sf /etc/nginx/sites-available/qrking /etc/nginx/sites-enabled/qrking
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx

say "5/6 Opening web ports in the firewall (if it is on)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 'Nginx Full'; else echo "Firewall is off, nothing to do."; fi

say "6/6 Turning on HTTPS (free Let's Encrypt certificate)"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect

say "Done. Open https://$DOMAIN"
