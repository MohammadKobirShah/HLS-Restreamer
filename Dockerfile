# ============================================================
# Kobir Shah Multi-Channel HLS Restreamer
# Version: 2.1.0 - Cloudflare Tunnel Integration
# ============================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------
# Install system packages
# --------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    ffmpeg \
    procps \
    iproute2 \
    curl \
    wget \
    ca-certificates \
    bash \
    logrotate \
    coreutils \
    findutils \
    gawk \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --------------------------------------------------------
# Install cloudflared (latest stable, amd64)
# Supports: Quick Tunnel (no account) + Named Tunnel (account)
# --------------------------------------------------------
RUN ARCH="$(dpkg --print-architecture)" && \
    case "$ARCH" in \
        amd64)   CF_ARCH="amd64" ;; \
        arm64)   CF_ARCH="arm64" ;; \
        armhf)   CF_ARCH="arm"   ;; \
        *)       echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    CF_VERSION=$(curl -fsSL \
        "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" \
        | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') && \
    echo "Installing cloudflared ${CF_VERSION} for ${CF_ARCH}..." && \
    curl -fsSL \
        "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-${CF_ARCH}" \
        -o /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared && \
    cloudflared --version

# --------------------------------------------------------
# Create dedicated non-root nginx worker user
# --------------------------------------------------------
RUN groupadd -r hlsgroup && \
    useradd -r -g hlsgroup -s /bin/false -d /nonexistent hlsuser

# --------------------------------------------------------
# Create directory structure
# --------------------------------------------------------
RUN mkdir -p \
        /root/hls \
        /root/logs \
        /root/locks \
        /root/probe_results \
        /root/tunnel \
        /var/cache/nginx \
        /var/log/nginx && \
    chmod 755 \
        /root \
        /root/hls \
        /root/logs \
        /root/locks \
        /root/probe_results \
        /root/tunnel && \
    chown -R hlsuser:hlsgroup \
        /root/hls \
        /root/logs \
        /var/cache/nginx \
        /var/log/nginx

# --------------------------------------------------------
# Copy configuration files
# --------------------------------------------------------
COPY nginx.conf          /root/nginx.conf
COPY logrotate.conf      /etc/logrotate.d/hls-restreamer
COPY start.sh            /start.sh

# Optional: named tunnel credentials (mount at runtime instead)
# COPY tunnel/config.yml /root/tunnel/config.yml

RUN chmod +x /start.sh && \
    chmod 644 /etc/logrotate.d/hls-restreamer

# --------------------------------------------------------
# Expose HTTP port (cloudflared connects to this internally)
# No need to expose 443 – cloudflare handles TLS termination
# --------------------------------------------------------
EXPOSE 8080

# --------------------------------------------------------
# Health check
# --------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -sf http://localhost:8080/health | grep -q "OK" || exit 1

WORKDIR /root

CMD ["/bin/bash", "/start.sh"]
