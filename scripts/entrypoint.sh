#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="

# Create ALL directories FIRST
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run /etc/nginx
chmod 777 /tmp/hls /var/www/html /var/run /var/log/nginx

# Create default master playlist IMMEDIATELY
cat > /var/www/html/master.m3u8 <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2000000
#EXTINF:-1,Loading channels...
#EXT-X-ENDLIST
EOF
chmod 644 /var/www/html/master.m3u8

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

# Kill any existing nginx
pkill nginx 2>/dev/null || true
sleep 2

# Test config
echo "Testing nginx config..."
nginx -t -c /etc/nginx/nginx.conf

# Start nginx with error logging
echo "Starting nginx..."
nginx -c /etc/nginx/nginx.conf 2>&1 || {
    echo "nginx start failed!"
    cat /var/log/nginx/error.log 2>/dev/null || true
    exit 1
}

# WAIT for nginx to be fully ready
echo "Waiting for nginx..."
for i in {1..10}; do
    sleep 1
    if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        echo "nginx ready!"
        break
    fi
    echo "  waiting... ($i)"
done

# Final verification
echo ""
echo "Verifying endpoints..."

# Test /health
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health)
echo "  /health: $HEALTH_STATUS"

# Test master.m3u8
MASTER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/master.m3u8)
echo "  /master.m3u8: $MASTER_STATUS"

# Show nginx processes
echo ""
echo "Nginx status:"
pgrep -a nginx || echo "nginx not running!"

# Check error log
if [ -f /var/log/nginx/error.log ]; then
    echo ""
    echo "Recent nginx errors:"
    tail -5 /var/log/nginx/error.log
fi

echo ""
echo "=== Starting Python App ==="
exec python3 -m src.restream
