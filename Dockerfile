# ============================================================
# Kobir Shah Multi-Channel HLS Restreamer – Optimized Edition
# ============================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install required packages with cleanup
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    ffmpeg \
    procps \
    iproute2 \
    curl \
    ca-certificates \
    bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Create working directories with proper permissions
RUN mkdir -p /root/hls /root/logs /root/nginx && \
    chmod 755 /root

# Copy configuration files
COPY nginx.conf  /root/nginx.conf
COPY start.sh    /start.sh
RUN chmod +x /start.sh

# Expose HTTP port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

WORKDIR /root

CMD ["/bin/bash", "/start.sh"]
