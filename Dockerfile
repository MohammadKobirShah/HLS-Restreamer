# ============================================================
# Kobir Shah Multi-Channel HLS Restreamer – Docker Edition
# ============================================================

FROM debian:bookworm-slim

# Install required packages
RUN apt-get update && apt-get install -y \
    nginx \
    ffmpeg \
    procps \
    net-tools \
    curl \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Create working directories
RUN mkdir -p /root/hls /root/logs /root/nginx

# Copy configuration and the startup script
COPY nginx.conf  /root/nginx.conf
COPY start.sh    /start.sh
RUN chmod +x /start.sh

# Inform Docker that the container listens on port 8080
EXPOSE 8080

# Run as root (nginx needs to write its pid and access /root)
USER root
WORKDIR /root

CMD ["/bin/bash", "/start.sh"]
