#!/bin/bash

set -e

echo "╔════════════════════════════════════════════╗"
echo "║   HLS RESTREAMING SERVER - STARTUP         ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# Detect container environment
IS_CONTAINER=false
if [ -f /proc/1/cgroup ] && grep -qiE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
fi
if grep -qi 'container=' /proc/1/environ 2>/dev/null; then
    IS_CONTAINER=true
fi

# Setup segment directory (RAM disk preferred, fallback to regular dir)
SEGMENT_DIR="/tmp/hls"
mkdir -p "$SEGMENT_DIR"

if [ "$IS_CONTAINER" = true ] || ! mountpoint -q "$SEGMENT_DIR"; then
    echo "Segment directory: $SEGMENT_DIR (standard storage)"
    chmod 777 "$SEGMENT_DIR" 2>/dev/null || true
else
    echo "Segment directory: $SEGMENT_DIR (RAM disk)"
fi

mkdir -p logs/channels

# Ensure Node.js dependencies are installed
if [ ! -d "node_modules" ] || [ ! -f "node_modules/.package-lock.json" ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
    echo "Installing Node.js dependencies..."
    npm install
fi

echo "Installing Python dependencies..."
pip3 install psutil requests --user 2>/dev/null || true

# Check that all modules load
echo "Verifying dependencies..."
node -e "
const mods = ['express','cors','helmet','compression','morgan','chalk','lowdb','uuid'];
for (const m of mods) { try { require(m); } catch(e) { console.error('Missing module:', m); process.exit(1); } }
console.log('All modules OK');
" 2>&1 || { echo "ERROR: Missing Node.js dependencies. Run: npm install"; exit 1; }

# Quick syntax check
node -c server.js 2>/dev/null || { echo "ERROR: server.js syntax check failed."; exit 1; }
node -c lib/channelManager.js 2>/dev/null || { echo "ERROR: channelManager.js syntax check failed."; exit 1; }

# Try PM2; fall back to nohup if unavailable
if command -v npx &>/dev/null && npx pm2 list &>/dev/null; then
    PM2="npx pm2"
    echo "Using PM2 process manager"

    echo "Stopping existing processes..."
    $PM2 delete hls-server 2>/dev/null || true
    $PM2 delete hls-cleanup 2>/dev/null || true

    echo "Starting HLS server..."
    $PM2 start server.js --name hls-server --time

    echo "Starting cleanup service..."
    $PM2 start cleanup.py --name hls-cleanup --interpreter python3 --time

    $PM2 save

    # Only attempt systemd auto-start if systemctl is available
    if command -v systemctl &>/dev/null; then
        echo "Setting up PM2 auto-start..."
        $PM2 startup systemd -u $(whoami) --hp $(eval echo ~$(whoami)) 2>/dev/null || true
    else
        echo "Auto-start not configured (systemd not available)"
    fi

    echo ""
    echo "Server started with PM2!"
    echo "Check status: pm2 status"
    echo "View logs:    pm2 logs"
else
    echo "PM2 not available — starting server directly with nohup"
    echo ""

    # Kill existing instances
    pkill -f "node server.js" 2>/dev/null || true
    pkill -f "python3 cleanup.py" 2>/dev/null || true

    echo "Starting HLS server..."
    nohup node server.js > logs/server-out.log 2>&1 &
    SERVER_PID=$!
    echo "Server PID: $SERVER_PID"

    echo "Starting cleanup service..."
    nohup python3 cleanup.py > logs/cleanup-out.log 2>&1 &
    CLEANUP_PID=$!
    echo "Cleanup PID: $CLEANUP_PID"

    echo ""
    echo "Server started without PM2!"
    echo "Stop with:  kill $SERVER_PID $CLEANUP_PID"
    echo "Monitor:    tail -f logs/server-out.log"
fi

echo ""
echo "Access admin panel: http://$(hostname -I 2>/dev/null | awk '{print $1}'):3000"
echo "Access player:      http://$(hostname -I 2>/dev/null | awk '{print $1}'):3000/player.html"
