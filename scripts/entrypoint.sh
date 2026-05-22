#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="

# Setup directories
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run /etc/nginx
chmod 777 /tmp/hls /var/www/html /var/run /var/log/nginx

# Create default master playlist
cat > /var/www/html/master.m3u8 <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXTINF:-1,Loading...
#EXT-X-ENDLIST
EOF
chmod 644 /var/www/html/master.m3u8

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Kill old nginx
pkill nginx 2>/dev/null || true
sleep 1

# Test config
nginx -t -c /etc/nginx/nginx.conf || exit 1

# Start nginx
echo "Starting nginx..."
nginx -c /etc/nginx/nginx.conf &
sleep 3

# Verify nginx
if ! pgrep nginx > /dev/null; then
    echo "ERROR: nginx failed"
    cat /var/log/nginx/error.log
    exit 1
fi

echo "nginx started"

# Wait a moment then verify endpoints
sleep 2

echo ""
echo "=== Testing Endpoints ==="
echo -n "/health: "
curl -sf http://localhost:8080/health && echo " OK" || echo " FAILED"

echo -n "/master.m3u8: "
curl -sf http://localhost:8080/master.m3u8 | head -2 && echo " OK" || echo " FAILED"

echo ""
echo "/tmp/hls directory:"
ls -la /tmp/hls/ 2>/dev/null || echo "  (empty or not created yet)"

echo ""
echo "=== Starting Python App ==="
exec python3 -m src.restream
