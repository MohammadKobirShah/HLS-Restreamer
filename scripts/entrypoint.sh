#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="
echo "Source: ${SOURCE_URL:-not set}"
echo "PORT: ${PORT:-8080}"

# Create ALL directories
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

# Test config
echo "Testing nginx config..."
nginx -t -c /etc/nginx/nginx.conf 2>&1 || {
    echo "Config test failed!"
    cat /etc/nginx/nginx.conf
    exit 1
}

# Kill old nginx
pkill nginx 2>/dev/null || true
sleep 1

# Start nginx
echo "Starting nginx..."
nginx -c /etc/nginx/nginx.conf
NGINX_PID=$!
sleep 3

# Verify nginx
if ! kill -0 $NGINX_PID 2>/dev/null; then
    echo "ERROR: nginx failed to start"
    cat /var/log/nginx/error.log 2>/dev/null || true
    exit 1
fi

echo "nginx started (PID: $NGINX_PID)"

# Test all endpoints
echo ""
echo "Testing endpoints..."

# Test /health
echo -n "/health: "
curl -sf --max-time 5 http://localhost:${PORT:-8080}/health && echo " ✓" || echo " ✗"

# Test /master.m3u8
echo -n "/master.m3u8: "
curl -sf --max-time 5 -A "Mozilla/5.0" http://localhost:${PORT:-8080}/master.m3u8 | head -3 && echo " ✓" || echo " ✗"

# Test /
echo -n "/: "
curl -sf --max-time 5 http://localhost:${PORT:-8080}/ && echo " ✓" || echo " ✗"

# Show nginx processes
echo ""
echo "Nginx processes:"
pgrep -a nginx || echo "No nginx found"

echo ""
echo "=== Starting Python App ==="
exec python3 -m src.restream
