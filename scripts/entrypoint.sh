#!/bin/bash
set -e

echo "=== Starting ==="
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run
chmod 777 /tmp/hls

# Copy nginx config if missing
[ ! -f /etc/nginx/nginx.conf ] && cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Test nginx config
nginx -c /etc/nginx/nginx.conf -t

# Start nginx
nginx -c /etc/nginx/nginx.conf &
sleep 3

# Verify nginx is running
if ! pgrep nginx > /dev/null; then
    echo "ERROR: nginx failed"
    cat /var/log/nginx/error.log
    exit 1
fi

echo "nginx running"

# Start Python app
exec python3 -m src.restream
