FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    build-essential git wget libpcre2-dev zlib1g-dev libssl-dev pkg-config ca-certificates \
    ffmpeg curl procps tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash app

WORKDIR /app

# Build nginx with RTMP
COPY build-nginx.sh /tmp/build-nginx.sh
RUN chmod +x /tmp/build-nginx.sh && /tmp/build-nginx.sh

# Copy app files
COPY requirements.txt ./
COPY src/ ./src/
COPY config/ ./config/

COPY scripts/entrypoint.sh /tmp/entrypoint.sh
COPY scripts/healthcheck.sh /tmp/healthcheck.sh
RUN chmod +x /tmp/entrypoint.sh /tmp/healthcheck.sh && \
    mv /tmp/entrypoint.sh /app/entrypoint.sh && \
    mv /tmp/healthcheck.sh /app/healthcheck.sh

# Install Python deps (NO uvloop - use standard asyncio)
RUN pip install --no-cache-dir -r requirements.txt

# Create directories
RUN mkdir -p /var/log/nginx /var/log/ffmpeg /tmp/hls /var/www/html /var/run && \
    chmod 777 /tmp/hls /var/www/html /var/run && \
    chown -R app:app /app /var/log /tmp/hls /var/www/html

ENV PYTHONUNBUFFERED=1 PORT=8080 NGINX_RTMP_PORT=1935
EXPOSE 8080 1935

ENTRYPOINT ["/app/entrypoint.sh"]
