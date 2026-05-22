#!/bin/bash
set -e

echo "=== Building nginx with RTMP module ==="

# Variables
NGINX_VERSION="1.24.0"
RTMP_MODULE_DIR="/tmp/nginx-rtmp-module"
NGINX_INSTALL_DIR="/usr/local/nginx"

# Install build deps
apt-get update -qq

# Clone RTMP module
git clone --depth 1 https://github.com/sergey-dryabzhinsky/nginx-rtmp-module.git "$RTMP_MODULE_DIR"

# Download nginx
cd /tmp
wget -q http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
tar -xzf nginx-${NGINX_VERSION}.tar.gz

# Configure nginx (no deprecated options)
cd nginx-${NGINX_VERSION}
./configure \
    --prefix=${NGINX_INSTALL_DIR} \
    --add-module=${RTMP_MODULE_DIR} \
    --with-http_ssl_module \
    --with-stream \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid

# Build
make -j$(nproc)

# Install
make install

# Clean up
cd /
rm -rf /tmp/nginx-*

echo "=== nginx build complete ==="
nginx -V
