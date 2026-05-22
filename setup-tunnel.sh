#!/bin/bash

echo "CLOUDFLARE TUNNEL SETUP"
echo "========================"
echo ""

if ! command -v cloudflared &> /dev/null; then
    echo "Installing cloudflared..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    sudo mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
    sudo chmod +x /usr/local/bin/cloudflared
fi

echo "Logging in to Cloudflare..."
cloudflared tunnel login

read -p "Enter tunnel name (default: hls-restreamer): " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-hls-restreamer}

echo "Creating tunnel: $TUNNEL_NAME..."
cloudflared tunnel create $TUNNEL_NAME

TUNNEL_ID=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')
echo "Tunnel ID: $TUNNEL_ID"

read -p "Enter your domain (e.g., stream.yourdomain.com): " DOMAIN

mkdir -p ~/.cloudflared

cat > ~/.cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: ~/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $DOMAIN
    service: http://localhost:3000
  - service: http_status:404
EOF

echo "Routing domain..."
cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN

echo "Starting tunnel with PM2..."
PM2="npx pm2"
$PM2 delete cloudflared 2>/dev/null || true
$PM2 start cloudflared --name cloudflared -- tunnel run $TUNNEL_NAME
$PM2 save

echo ""
echo "Cloudflare Tunnel configured!"
echo "Your server is accessible at: https://$DOMAIN"
echo ""
echo "Next steps:"
echo "1. Go to https://$DOMAIN to access admin panel"
echo "2. Add channels via the web interface"
echo "3. Stream URLs will be: https://$DOMAIN/hls/CHANNEL_NAME/index.m3u8"
