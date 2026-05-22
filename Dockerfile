FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    build-essential git wget libpcre2-dev zlib1g-dev libssl-dev pkg-config ca-certificates \
    ffmpeg curl procps tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Build nginx with RTMP
COPY build-nginx.sh /tmp/build-nginx.sh
RUN chmod +x /tmp/build-nginx.sh && /tmp/build-nginx.sh

# Copy files
COPY requirements.txt ./
COPY src/ ./src/
COPY config/ ./config/
COPY scripts/entrypoint.sh /app/entrypoint.sh
COPY scripts/healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

# Install Python deps
RUN pip install --no-cache-dir -r requirements.txt

# Create directories
RUN mkdir -p /var/log/nginx /var/log/ffmpeg /var/www/html /var/run /etc/nginx && \
    chmod 777 /var/www/html /tmp && \
    touch /var/www/html/master.m3u8 && \
    chmod 644 /var/www/html/master.m3u8

ENV PYTHONUNBUFFERED=1 PORT=8080 NGINX_RTMP_PORT=1935
EXPOSE 8080 1935

ENTRYPOINT ["/app/entrypoint.sh"]
