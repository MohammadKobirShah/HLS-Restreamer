#!/bin/bash
set -e

echo "=== RESTREAM-HLS Entry Point ==="
echo "Source URL: ${SOURCE_URL}"
echo "HTTP Port: ${PORT}"
echo "RTMP Port: ${NGINX_RTMP_PORT}"

# Create required directories
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html

# Set permissions
chmod 777 /tmp/hls

# Generate nginx config from template
envsubst < /app/config/nginx.conf > /tmp/nginx.conf

# Start in background
echo "Starting nginx..."
/usr/local/nginx/sbin/nginx -c /tmp/nginx.conf &

echo "Starting Python app..."
exec python3 -m src.restream
