# ============================================
# Stage 1: Builder
# ============================================
FROM python:3.11-slim as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    libpcre3 \
    libpcre3-dev \
    zlib1g-dev \
    libssl-dev \
    pkg-config \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Build nginx with RTMP module
RUN git clone https://github.com/sergey-dryabzhinsky/nginx-rtmp-module.git /tmp/nginx-rtmp \
    && wget -qO- http://nginx.org/download/nginx-1.24.0.tar.gz | tar -xz -C /tmp \
    && cd /tmp/nginx-1.24.0 \
    && ./configure \
        --add-module=/tmp/nginx-rtmp \
        --with-http_ssl_module \
        --with-http_gzip_static \
        --with-stream \
        --with-stream_ssl_module \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/nginx-* /tmp/nginx-rtmp

# ============================================
# Stage 2: Runtime
# ============================================
FROM python:3.11-slim

LABEL maintainer="restream-hls"
LABEL description="Low-latency HLS restreamer without transcoding"

# Install runtime deps
RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    procps \
    tzdata \
    # For tmpfs simulation on Railway (RAM disk)
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash app

WORKDIR /app

# Copy nginx binary from builder
COPY --from=builder /usr/local/nginx /usr/local/nginx
COPY --from=builder /usr/local/nginx/sbin/nginx /usr/local/nginx/sbin/nginx

# Copy application files
COPY requirements.txt .
COPY src/ ./src/
COPY config/ ./config/
COPY scripts/ ./scripts/

# Create directories
RUN mkdir -p /var/log/nginx \
             /var/log/ffmpeg \
             /tmp/hls \
             /var/www/html

# Set permissions
RUN chown -R app:app /app /var/log /tmp/hls /var/www/html

# Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Environment defaults
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080 \
    NGINX_RTMP_PORT=1935 \
    HLS_FRAGMENT=10 \
    HLS_PLIST_LENGTH=15 \
    LOG_LEVEL=INFO \
    CHANNEL_REFRESH=60

# Expose ports
EXPOSE 8080 1935

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /app/scripts/healthcheck.sh

USER app

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
