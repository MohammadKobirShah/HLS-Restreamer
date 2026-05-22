FROM python:3.11-slim

# Install dependencies and create user
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    libpcre2-dev \
    zlib1g-dev \
    libssl-dev \
    pkg-config \
    wget \
    ca-certificates \
    ffmpeg \
    curl \
    procps \
    tzdata \
    && useradd -m -u 1000 -s /bin/bash app \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Build nginx with RTMP module
COPY build-nginx.sh /tmp/build-nginx.sh
RUN chmod +x /tmp/build-nginx.sh && /tmp/build-nginx.sh

# Copy application files
COPY requirements.txt ./
COPY src/ ./src/
COPY config/ ./config/
COPY scripts/ ./scripts/

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Create directories and set proper permissions
RUN mkdir -p /var/log/nginx /var/log/ffmpeg /tmp/hls /var/www/html && \
    chown -R app:app /app /var/log/nginx /var/log/ffmpeg /tmp/hls /var/www/html && \
    chmod +x /app/scripts/entrypoint.sh

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PORT=8080 \
    NGINX_RTMP_PORT=1935

# Expose ports
EXPOSE 8080 1935

# Switch to non-root user
USER app

# Start application
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
