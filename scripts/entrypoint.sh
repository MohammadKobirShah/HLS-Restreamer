#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="
echo "Source URL: ${SOURCE_URL:-not set}"

# Create directories
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run
chmod 777 /tmp/hls /var/www/html

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Test nginx config
nginx -t -c /etc/nginx/nginx.conf

# Start nginx
nginx -c /etc/nginx/nginx.conf
sleep 2

# Verify nginx
if pgrep -x nginx > /dev/null; then
    echo "OK"
    curl -sf http://localhost:${PORT:-8080}/health && echo " - Health OK"
else
    echo "ERROR: nginx failed to start"
    cat /var/log/nginx/error.log 2>/dev/null || true
    exit 1
fi

# Start Python app
exec python3 -m src.restream
