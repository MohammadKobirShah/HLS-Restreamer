FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY . .

RUN pip3 install --no-cache-dir psutil requests 2>/dev/null || true

RUN mkdir -p /tmp/hls logs

EXPOSE 3000

CMD ["node", "server.js"]
