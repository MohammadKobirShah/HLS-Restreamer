#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="

# Create ALL required directories
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run /etc/nginx

# Set proper permissions
chmod -R 777 /tmp/hls /var/www/html /var/run
chmod -R 755 /var/log/nginx

# Create default master playlist if doesn't exist
if [ ! -f /var/www/html/master.m3u8 ]; then
    echo "#EXTM3U" > /var/www/html/master.m3u8
    echo "#EXT-X-VERSION:3" >> /var/www/html/master.m3u8
    echo "#EXTINF:-1,No channels" >> /var/www/html/master.m3u8
    echo "#EXT-X-ENDLIST" >> /var/www/html/master.m3u8
    echo "Created default master.m3u8"
fi

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Verify nginx config
nginx -t -c /etc/nginx/nginx.conf

# Stop any existing nginx
pkill nginx 2>/dev/null || true
sleep 1

# Start nginx
nginx -c /etc/nginx/nginx.conf
sleep 2

# Verify nginx is running
if ! pgrep -x nginx > /dev/null; then
    echo "ERROR: nginx failed to start"
    cat /var/log/nginx/error.log || true
    exit 1
fi

echo "OK"

# Test health
curl -sf http://localhost:${PORT:-8080}/health && echo " - Health OK" || echo " - Health check failed"

# Test master.m3u8
curl -sf http://localhost:${PORT:-8080}/master.m3u8 && echo " - Master playlist OK" || echo " - Master playlist failed"

# Start Python app
exec python3 -m src.restream
