#!/bin/bash
set -e

echo "=== RESTREAM-HLS ==="

# ============================================
# STEP 1: Setup
# ============================================
mkdir -p /tmp/hls /var/log/nginx /var/log/ffmpeg /var/www/html /var/run /etc/nginx
chmod 777 /tmp/hls /var/www/html /var/run /var/log/nginx

# Create default master playlist
cat > /var/www/html/master.m3u8 <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=2000000
#EXTINF:-1,Loading...
#EXT-X-ENDLIST
EOF
chmod 644 /var/www/html/master.m3u8

# Copy nginx config
cp /app/config/nginx.conf /etc/nginx/nginx.conf

echo "Config copied"

# ============================================
# STEP 2: Start nginx
# ============================================
pkill nginx 2>/dev/null || true
sleep 1

# Test config
nginx -t -c /etc/nginx/nginx.conf || {
    echo "Config test failed"
    cat /etc/nginx/nginx.conf
    exit 1
}

# Start nginx
nginx -c /etc/nginx/nginx.conf &
NGINX_PID=$!

echo "nginx started (PID: $NGINX_PID)"

# ============================================
# STEP 3: Wait for nginx to be ready
# ============================================
echo "Waiting for nginx to be ready..."
READY=0
for i in {1..15}; do
    sleep 1
    
    # Check if nginx is running
    if ! kill -0 $NGINX_PID 2>/dev/null; then
        echo "ERROR: nginx died!"
        cat /var/log/nginx/error.log 2>/dev/null || true
        exit 1
    fi
    
    # Check if it's responding
    if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        READY=1
        echo "nginx is ready!"
        break
    fi
    
    echo "  attempt $i..."
done

if [ $READY -eq 0 ]; then
    echo "ERROR: nginx did not become ready in time"
    echo "nginx status:"
    ps aux | grep nginx
    echo ""
    echo "error log:"
    cat /var/log/nginx/error.log 2>/dev/null || true
    echo ""
    echo "access log:"
    tail -10 /var/log/nginx/access.log 2>/dev/null || true
    exit 1
fi

# ============================================
# STEP 4: Final verification
# ============================================
echo ""
echo "=== Verification ==="
echo "nginx PID: $(pgrep nginx)"
echo "/health: $(curl -s http://localhost:8080/health)"
echo "/master.m3u8: $(curl -s http://localhost:8080/master.m3u8 | head -3)"
echo ""

# ============================================
# STEP 5: Start Python
# ============================================
echo "=== Starting Python App ==="
exec python3 -m src.restream
