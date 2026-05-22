#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run
chmod 777 /tmp/hls /var/www/html

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Start nginx
nginx -c /etc/nginx/nginx.conf &
sleep 3

# Health check
curl -sf http://localhost:${PORT:-8080}/health && echo " - Health OK" || echo " - Health check failed"

# Start Python
exec python3 -m src.restream
