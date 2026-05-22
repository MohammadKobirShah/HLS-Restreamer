#!/bin/bash

set -e

echo "╔════════════════════════════════════════════╗"
echo "║   HLS RESTREAMING SERVER INSTALLER         ║"
echo "║   Node.js + Python Edition                 ║"
echo "╚════════════════════════════════════════════╝"
echo ""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS"
    exit 1
fi

echo "Updating system packages..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt update
    sudo apt install -y curl wget git build-essential
elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ]; then
    sudo yum install -y curl wget git gcc-c++ make
fi

echo "Installing Node.js 20.x..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs || sudo yum install -y nodejs

echo "Installing Python 3..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt install -y python3 python3-pip
else
    sudo yum install -y python3 python3-pip
fi

echo "Installing FFmpeg..."
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt install -y ffmpeg
else
    sudo yum install -y epel-release
    sudo yum install -y ffmpeg
fi

echo "Installing PM2 process manager..."
# Clean up stale npm artifacts (common in containers)
rm -rf /usr/lib/node_modules/pm2 /usr/lib/node_modules/.pm2-* 2>/dev/null || true
npm cache clean --force 2>/dev/null || true

# Try global install first, fall back to local project install
if npm install -g pm2 2>/dev/null; then
    echo "PM2 installed globally"
else
    echo "Global install failed, installing locally in project..."
    npm install pm2 --save
fi

echo "Installing Cloudflare Tunnel..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
sudo mv cloudflared-linux-amd64 /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared

echo "Creating project structure..."
mkdir -p ~/hls-restreamer
cd ~/hls-restreamer
mkdir -p {public/css,lib,logs/channels,segments}

# Detect container environment
IS_CONTAINER=false
if [ -f /proc/1/cgroup ] && grep -qiE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
    IS_CONTAINER=true
fi

# Setup segment directory — RAM disk if possible
mkdir -p /tmp/hls
chmod 777 /tmp/hls

if [ "$IS_CONTAINER" = false ] && command -v mountpoint &>/dev/null && ! mountpoint -q /tmp/hls && command -v mount &>/dev/null; then
    if mount -t tmpfs -o size=2G tmpfs /tmp/hls 2>/dev/null; then
        echo "RAM disk created (2GB) at /tmp/hls"
        echo "tmpfs /tmp/hls tmpfs size=2G,mode=0777 0 0" >> /etc/fstab 2>/dev/null || true
    else
        echo "Note: RAM disk not available, using standard storage for /tmp/hls"
    fi
else
    echo "Note: Running in container — using standard storage for /tmp/hls"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. cd ~/hls-restreamer"
echo "2. Create all project files"
echo "3. Run: npm install"
echo "4. Run: chmod +x start.sh"
echo "5. Run: ./start.sh"
