#!/usr/bin/env bash
# QRKing: put the site on this server with HTTPS. Safe to run again (it updates the site).
# Usage (as root):  curl -fsSL https://raw.githubusercontent.com/darlingbo/qrking-site/main/setup.sh | bash
set -euo pipefail

DOMAIN="${DOMAIN:-144-202-58-251.sslip.io}"   # free name that points to this server; change when you buy a domain
WEBROOT="/var/www/qrking"
REPO="https://github.com/darlingbo/qrking-site.git"

say(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "1/7 Checking ports 80 and 443 are free (so we don't disturb other apps)"
if ss -tlnp | grep -E ':(80|443)\s' | grep -vq nginx; then
  ss -tlnp | grep -E ':(80|443)\s'
  echo "Another program is using port 80 or 443. Stopping so nothing breaks. Send this output to Claude."
  exit 1
fi

say "2/7 Installing nginx, git and certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx git python3 certbot python3-certbot-nginx >/dev/null

say "3/7 Getting the site files"
if [ -d "$WEBROOT/.git" ]; then git -C "$WEBROOT" pull --ff-only; else rm -rf "$WEBROOT"; git clone --depth 1 "$REPO" "$WEBROOT"; fi

say "4/7 Starting the waitlist saver (sign-ups go to /var/lib/qrking/waitlist.csv)"
cat > /etc/systemd/system/qrking-waitlist.service <<EOF
[Unit]
Description=QRKing waitlist saver
After=network.target

[Service]
ExecStart=/usr/bin/python3 $WEBROOT/waitlist_server.py --port 8795
DynamicUser=yes
StateDirectory=qrking
StateDirectoryMode=0700
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable qrking-waitlist >/dev/null 2>&1
systemctl restart qrking-waitlist

say "5/7 Setting up nginx for $DOMAIN"
cat > /etc/nginx/sites-available/qrking <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
    location ~ /\.git { deny all; }
    location = /setup.sh { deny all; }
    location ~ \.py\$ { deny all; }
    location = /api/waitlist {
        limit_except POST { deny all; }
        client_max_body_size 2k;
        proxy_pass http://127.0.0.1:8795;
        proxy_set_header X-Real-IP \$remote_addr;
    }
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

say "6/7 Opening web ports in the firewall (if it is on)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 'Nginx Full'; else echo "Firewall is off, nothing to do."; fi

say "7/7 Turning on HTTPS (free Let's Encrypt certificate)"
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect

say "Done. Open https://$DOMAIN"
echo "See who joined the waitlist:  cat /var/lib/qrking/waitlist.csv"
