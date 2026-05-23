# 𝗞𝗼𝗯𝗶𝗿 𝗦𝗵𝗮𝗵 · 𝗛𝗟𝗦 𝗥𝗲𝘀𝘁𝗿𝗲𝗮𝗺𝗲𝗿

<div align="center">

![Banner](https://capsule-render.vercel.app/api?type=waving&color=0:0d1117,50:1a1f35,100:0d1117&height=200&section=header&text=HLS%20Restreamer&fontSize=52&fontColor=58a6ff&fontAlignY=38&desc=Multi-Channel%20Live%20Stream%20Relay%20%2B%20Cloudflare%20Tunnel&descAlignY=58&descColor=8b949e&animation=fadeIn)

[![Version](https://img.shields.io/badge/Version-2.1.0-58a6ff?style=for-the-badge&logo=git&logoColor=white)](https://github.com/MohammadKobirShah/hls-restreamer)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://hub.docker.com/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-Powered-007808?style=for-the-badge&logo=ffmpeg&logoColor=white)](https://ffmpeg.org/)
[![Nginx](https://img.shields.io/badge/Nginx-Optimized-009639?style=for-the-badge&logo=nginx&logoColor=white)](https://nginx.org/)
[![Cloudflare](https://img.shields.io/badge/Cloudflare-Tunnel-F48120?style=for-the-badge&logo=cloudflare&logoColor=white)](https://www.cloudflare.com/)
[![License](https://img.shields.io/badge/License-MIT-3fb950?style=for-the-badge&logo=opensourceinitiative&logoColor=white)](LICENSE)

<br/>

> **𝗙𝘂𝗹𝗹𝘆 𝗮𝘂𝘁𝗼𝗺𝗮𝘁𝗲𝗱**, **𝗽𝗿𝗼𝗱𝘂𝗰𝘁𝗶𝗼𝗻-𝗿𝗲𝗮𝗱𝘆** multi-channel HLS restreamer
> that converts any M3U playlist into low-latency HLS streams
> and exposes them globally via **Cloudflare Tunnel** — with zero port forwarding.

<br/>

[𝗤𝘂𝗶𝗰𝗸 𝗦𝘁𝗮𝗿𝘁](#-quick-start) •
[𝗗𝗼𝗰𝘂𝗺𝗲𝗻𝘁𝗮𝘁𝗶𝗼𝗻](#-how-it-works) •
[𝗖𝗼𝗻𝗳𝗶𝗴𝘂𝗿𝗮𝘁𝗶𝗼𝗻](#️-configuration) •
[𝗗𝗲𝗽𝗹𝗼𝘆](#-deployment-modes) •
[𝗙𝗔𝗤](#-faq)

</div>

---

## 𝗪𝗵𝗮𝘁 𝗶𝘀 𝘁𝗵𝗶𝘀?

**HLS Restreamer** takes any **M3U / M3U8 playlist** (cable TV, IPTV, live sports, news)
and re-publishes every channel as a clean **HLS stream** served over HTTP —
accessible from **anywhere in the world** through a Cloudflare Tunnel,
with no router configuration, no VPS firewall rules, and **no open ports** required.

```
  Your M3U Playlist
        │
        ▼
  ┌─────────────────────────────────────────────────────┐
  │              HLS Restreamer Container               │
  │                                                     │
  │  M3U Parser → FFmpeg (per channel) → HLS Segments  │
  │       └──────────── Nginx :8080 ───────────────┘   │
  │                         │                           │
  │               Cloudflare Tunnel                     │
  └─────────────────────────────────────────────────────┘
                            │
                            ▼
              https://xxxx.trycloudflare.com
              https://stream.yourdomain.com
```

---

## ✨ 𝗙𝗲𝗮𝘁𝘂𝗿𝗲𝘀

<table>
<tr>
<td width="50%">

### 🎯 𝗖𝗼𝗿𝗲
- ✅ Parse unlimited M3U / M3U8 channels
- ✅ Per-channel FFmpeg HLS transcoding
- ✅ **2-second** segment latency
- ✅ Audio track detection: **Bengali → Hindi → Default**
- ✅ Automatic channel restart on failure
- ✅ Live TUI monitor dashboard
- ✅ JSON stats API at `/stats`

</td>
<td width="50%">

### ☁️ 𝗖𝗹𝗼𝘂𝗱𝗳𝗹𝗮𝗿𝗲
- ✅ **Quick Tunnel** — no account needed
- ✅ **Named Tunnel** — stable custom domain
- ✅ Auto-detects tunnel URL
- ✅ Tunnel watchdog auto-restarts on crash
- ✅ Real IP headers from Cloudflare
- ✅ HTTPS termination handled by Cloudflare
- ✅ Zero port forwarding required

</td>
</tr>
<tr>
<td width="50%">

### ⚡ 𝗣𝗲𝗿𝗳𝗼𝗿𝗺𝗮𝗻𝗰𝗲
- ✅ Parallel audio probing (configurable workers)
- ✅ Nginx sendfile + epoll + file cache
- ✅ Direct I/O for TS segments
- ✅ Rate limiting per endpoint type
- ✅ Log rotation (10MB cap per log)
- ✅ Disk space pre-flight check

</td>
<td width="50%">

### 🔒 𝗦𝗲𝗰𝘂𝗿𝗶𝘁𝘆
- ✅ Nginx runs as non-root `hlsuser`
- ✅ URL scheme validation (SSRF prevention)
- ✅ Hidden file access blocked
- ✅ CORS headers on all responses
- ✅ Duplicate URL deduplication
- ✅ Reserved path collision protection

</td>
</tr>
</table>

---

## 🚀 𝗤𝘂𝗶𝗰𝗸 𝗦𝘁𝗮𝗿𝘁

### 𝗢𝗻𝗲-𝗟𝗶𝗻𝗲𝗿 (Quick Tunnel — no account needed)

```bash
docker run -d \
  --name hls-relay \
  --restart unless-stopped \
  -p 8080:8080 \
  -e M3U_URL="https://example.com/playlist.m3u" \
  -e CF_TUNNEL_MODE="quick" \
  ghcr.io/mohammadkobirshah/hls-restreamer:2.1.0
```

> 𝗬𝗼𝘂𝗿 𝗽𝘂𝗯𝗹𝗶𝗰 𝗨𝗥𝗟 𝗮𝗽𝗽𝗲𝗮𝗿𝘀 𝗶𝗻 ~𝟯𝟬 𝘀𝗲𝗰𝗼𝗻𝗱𝘀:

```bash
docker exec hls-relay cat /root/tunnel_url.txt
# → https://random-words-here.trycloudflare.com
```

---

## 📁 𝗣𝗿𝗼𝗷𝗲𝗰𝘁 𝗦𝘁𝗿𝘂𝗰𝘁𝘂𝗿𝗲

```
hls-restreamer/
├── 📄 Dockerfile           # Multi-arch image with cloudflared
├── 📄 start.sh             # Main orchestrator script
├── 📄 nginx.conf           # Optimized HLS delivery config
├── 📄 logrotate.conf       # Log rotation (10MB cap)
└── 📁 tunnel/
    └── 📄 config.yml       # Optional: named tunnel credentials
```

---

## 🔧 𝗛𝗼𝘄 𝗜𝘁 𝗪𝗼𝗿𝗸𝘀

```
 STARTUP SEQUENCE
 ────────────────────────────────────────────────────────────
  1. Download / mount M3U playlist
  2. Parse channels → deduplicate URLs and folder names
  3. Disk space pre-flight check
  4. Parallel FFprobe audio detection (Bengali / Hindi / Default)
  5. Validate nginx config → start nginx on :8080
  6. Start Cloudflare Tunnel (quick or named)
  7. Launch one FFmpeg process per channel
  8. Wait 20s → generate master + restream playlists
  9. Enter monitor loop (5s refresh)

 MONITOR LOOP (every 5 seconds)
 ────────────────────────────────────────────────────────────
  • Check each channel's FFmpeg PID
  • Auto-restart dead channels after 15s downtime
  • Lock file prevents duplicate FFmpeg spawning
  • Regenerate playlists every 30s
  • Write /stats JSON every loop
  • Rotate logs every 5 minutes (if needed)
  • Watchdog keeps cloudflared alive
```

---

## 🌐 𝗗𝗲𝗽𝗹𝗼𝘆𝗺𝗲𝗻𝘁 𝗠𝗼𝗱𝗲𝘀

### 𝗠𝗼𝗱𝗲 𝟭 — 𝗤𝘂𝗶𝗰𝗸 𝗧𝘂𝗻𝗻𝗲𝗹 ⚡

> No account. No config. Instant public URL.
> URL changes on every restart.

```bash
docker run -d \
  --name hls-relay \
  --restart unless-stopped \
  -p 8080:8080 \
  -e M3U_URL="https://example.com/playlist.m3u" \
  -e CF_TUNNEL_MODE="quick" \
  ghcr.io/mohammadkobirshah/hls-restreamer:2.1.0
```

<details>
<summary>𝗦𝗲𝗲 𝗼𝘂𝘁𝗽𝘂𝘁 𝗲𝘅𝗮𝗺𝗽𝗹𝗲</summary>

```
[09:12:01] [OK]    Nginx up on :8080
[09:12:04] [TUNNEL] Starting Cloudflare Quick Tunnel...
[09:12:31] [OK]    ╔══════════════════════════════════════════════╗
[09:12:31] [OK]    ║  Cloudflare Quick Tunnel is LIVE!            ║
[09:12:31] [OK]    ║                                              ║
[09:12:31] [OK]    ║  Public URL: https://abc-def.trycloudflare.com
[09:12:31] [OK]    ║  Playlist:                                   ║
[09:12:31] [OK]    ║  https://abc-def.trycloudflare.com/restream_playlist.m3u8
[09:12:31] [OK]    ╚══════════════════════════════════════════════╝
```

</details>

---

### 𝗠𝗼𝗱𝗲 𝟮 — 𝗡𝗮𝗺𝗲𝗱 𝗧𝘂𝗻𝗻𝗲𝗹 🔒

> Stable custom domain. Requires free Cloudflare account.
> URL never changes. Perfect for production.

#### 𝗦𝗲𝘁𝘂𝗽 (𝗼𝗻𝗲 𝘁𝗶𝗺𝗲 𝗼𝗻𝗹𝘆)

```
1. Create account → https://dash.cloudflare.com (free)
2. Add your domain to Cloudflare (or use a free subdomain)
3. Go to: Zero Trust → Networks → Tunnels → Create tunnel
4. Name it: hls-relay → Save
5. Copy the token from the install command shown
6. In "Public Hostname" tab:
     Subdomain : stream
     Domain    : yourdomain.com
     Service   : HTTP → localhost:8080
7. Save hostname
```

```bash
docker run -d \
  --name hls-relay \
  --restart unless-stopped \
  -p 8080:8080 \
  -e M3U_URL="https://example.com/playlist.m3u" \
  -e CF_TUNNEL_MODE="named" \
  -e CF_TUNNEL_TOKEN="eyJhIjoiYWJjZGVmZ2hpams..." \
  -e PUBLIC_DOMAIN="https://stream.yourdomain.com" \
  ghcr.io/mohammadkobirshah/hls-restreamer:2.1.0
```

---

### 𝗠𝗼𝗱𝗲 𝟯 — 𝗡𝗼 𝗧𝘂𝗻𝗻𝗲𝗹 (𝗬𝗼𝘂𝗿 𝗢𝘄𝗻 𝗣𝗿𝗼𝘅𝘆) 🛠️

> Use your own Nginx / Caddy / Traefik reverse proxy.

```bash
docker run -d \
  --name hls-relay \
  --restart unless-stopped \
  -p 8080:8080 \
  -e M3U_URL="https://example.com/playlist.m3u" \
  -e CF_TUNNEL_MODE="disabled" \
  -e PUBLIC_DOMAIN="https://stream.yourdomain.com" \
  ghcr.io/mohammadkobirshah/hls-restreamer:2.1.0
```

---

### 𝗟𝗼𝗰𝗮𝗹 𝗣𝗹𝗮𝘆𝗹𝗶𝘀𝘁 𝗠𝗼𝘂𝗻𝘁

```bash
docker run -d \
  --name hls-relay \
  --restart unless-stopped \
  -p 8080:8080 \
  -v "$(pwd)/playlist.m3u:/root/playlist.m3u:ro" \
  -e CF_TUNNEL_MODE="quick" \
  ghcr.io/mohammadkobirshah/hls-restreamer:2.1.0
```

---

## ⚙️ 𝗖𝗼𝗻𝗳𝗶𝗴𝘂𝗿𝗮𝘁𝗶𝗼𝗻

### 𝗘𝗻𝘃𝗶𝗿𝗼𝗻𝗺𝗲𝗻𝘁 𝗩𝗮𝗿𝗶𝗮𝗯𝗹𝗲𝘀

| Variable | Description | Default |
|----------|-------------|---------|
| `M3U_URL` | Remote M3U playlist URL to download | *(mount file instead)* |
| `CF_TUNNEL_MODE` | `quick` \| `named` \| `disabled` | `quick` |
| `CF_TUNNEL_TOKEN` | Token from Cloudflare dashboard | *(required for named)* |
| `PUBLIC_DOMAIN` | Override public URL in playlists | *(auto from tunnel)* |
| `MAX_PROBE_JOBS` | Parallel FFprobe worker count | `8` |

### 𝗕𝘂𝗶𝗹𝗱-𝗧𝗶𝗺𝗲 𝗖𝗼𝗻𝘀𝘁𝗮𝗻𝘁𝘀 (𝗶𝗻 `start.sh`)

| Constant | Description | Default |
|----------|-------------|---------|
| `HLS_SEGMENT_DURATION` | HLS segment length in seconds | `2` |
| `HLS_LIST_SIZE` | Segments kept in playlist | `4` |
| `STARTUP_WAIT_SECONDS` | Wait before first segment check | `20` |
| `RESTART_THRESHOLD` | Seconds down before auto-restart | `15` |
| `MONITOR_INTERVAL` | Dashboard refresh rate (seconds) | `5` |
| `MIN_DISK_MB_PER_CHANNEL` | Disk estimate per channel | `25` |

---

## 🌍 𝗘𝗻𝗱𝗽𝗼𝗶𝗻𝘁𝘀

| Endpoint | Description | Content-Type |
|----------|-------------|--------------|
| `/health` | Health check (returns `OK`) | `text/plain` |
| `/status` | Web dashboard (auto-refreshes) | `text/html` |
| `/stats` | JSON stats for all channels | `application/json` |
| `/tunnel` | Cloudflare tunnel info JSON | `application/json` |
| `/master.m3u8` | Master HLS playlist (localhost URLs) | `application/vnd.apple.mpegurl` |
| `/restream_playlist.m3u8` | Public playlist (tunnel URLs) | `application/vnd.apple.mpegurl` |
| `/{channel}/` | Per-channel HLS directory | — |
| `/{channel}/{channel}.m3u8` | Per-channel HLS playlist | `application/vnd.apple.mpegurl` |
| `/{channel}/segment_XXXXX.ts` | HLS transport stream segment | `video/mp2t` |

---

## 📊 𝗦𝘁𝗮𝘁𝘀 𝗔𝗣𝗜

```bash
curl -s https://xxxx.trycloudflare.com/stats | python3 -m json.tool
```

```json
{
  "version": "2.1.0",
  "generated": "2024-01-15T09:30:00Z",
  "uptime": "02h15m30s",
  "uptime_seconds": 8130,
  "total_channels": 42,
  "active": 40,
  "starting": 1,
  "down": 1,
  "public_url": "https://xxxx.trycloudflare.com",
  "tunnel": {
    "status": "online",
    "type": "quick",
    "url": "https://xxxx.trycloudflare.com"
  },
  "channels": [
    {
      "index": 0,
      "name": "Star Sports HD",
      "folder": "starsportshd",
      "url": "https://xxxx.trycloudflare.com/starsportshd/starsportshd.m3u8",
      "state": "active",
      "audio_lang": "Bengali",
      "segments": 4
    }
  ]
}
```

---

## 🖥️ 𝗧𝗨𝗜 𝗗𝗮𝘀𝗵𝗯𝗼𝗮𝗿𝗱

```
╔══════════════════════════════════════════════════════════════════════╗
║       KOBIR SHAH – HLS RESTREAMER v2.1.0 + CLOUDFLARE TUNNEL      ║
╚══════════════════════════════════════════════════════════════════════╝

  ☁  Tunnel:   LIVE → https://abc-def-ghi.trycloudflare.com
  Local:       http://localhost:8080
  Playlist:    https://abc-def-ghi.trycloudflare.com/restream_playlist.m3u8
  Channels:    42
  Time:        2024-01-15 09:30:00  │  Up: 02h 15m 30s

  #   CHANNEL                    STATE       SEGS  UPDATED    AUDIO
  ────────────────────────────────────────────────────────────────────
  1   Star Sports HD             ● ACTIVE    4     2s ago     Bengali
  2   Sony Sports 1              ● ACTIVE    4     3s ago     Bengali
  3   Sony Sports 2              ● ACTIVE    4     1s ago     Hindi
  4   Zee TV HD                  ● ACTIVE    4     2s ago     Bengali
  5   Colors HD                  ● STARTING  0     restarting Auto
  6   Bad Source Channel..       ● DOWN      0     -          Auto
  ────────────────────────────────────────────────────────────────────
  ● Active: 40    ◑ Starting: 1    ○ Down: 1
```

---

## 🏗️ 𝗕𝘂𝗶𝗹𝗱 𝗙𝗿𝗼𝗺 𝗦𝗼𝘂𝗿𝗰𝗲

```bash
# Clone
git clone https://github.com/MohammadKobirShah/hls-restreamer.git
cd hls-restreamer

# Build
docker build -t hls-restreamer:2.1.0 .

# Run
docker run -d \
  --name hls-relay \
  -p 8080:8080 \
  -e M3U_URL="https://example.com/playlist.m3u" \
  -e CF_TUNNEL_MODE="quick" \
  hls-restreamer:2.1.0
```

---

## 🐛 𝗧𝗿𝗼𝘂𝗯𝗹𝗲𝘀𝗵𝗼𝗼𝘁𝗶𝗻𝗴

<details>
<summary><b>𝗧𝘂𝗻𝗻𝗲𝗹 𝗨𝗥𝗟 𝗻𝗼𝘁 𝗮𝗽𝗽𝗲𝗮𝗿𝗶𝗻𝗴</b></summary>

```bash
# Check cloudflared log
docker exec hls-relay tail -50 /root/logs/cloudflared.log

# Check tunnel.json
docker exec hls-relay cat /root/hls/tunnel.json

# Manually check if cloudflared is running
docker exec hls-relay pgrep -a cloudflared
```

</details>

<details>
<summary><b>𝗖𝗵𝗮𝗻𝗻𝗲𝗹𝘀 𝘀𝘁𝗮𝘆𝗶𝗻𝗴 𝗗𝗢𝗪𝗡</b></summary>

```bash
# Check FFmpeg log for a specific channel
docker exec hls-relay tail -50 /root/logs/ffmpeg_channelname.log

# List all FFmpeg processes
docker exec hls-relay pgrep -a ffmpeg

# Check segments exist
docker exec hls-relay ls -la /root/hls/channelname/
```

</details>

<details>
<summary><b>𝗡𝗼 𝗮𝘂𝗱𝗶𝗼 / 𝘄𝗿𝗼𝗻𝗴 𝗮𝘂𝗱𝗶𝗼 𝘁𝗿𝗮𝗰𝗸</b></summary>

```bash
# Manually probe a stream's audio tracks
docker exec hls-relay ffprobe \
  -v error \
  -select_streams a \
  -show_entries stream=index:stream_tags=language \
  -of csv=p=0 \
  "https://your-stream-url"
```

</details>

<details>
<summary><b>𝗗𝗶𝘀𝗸 𝗳𝘂𝗹𝗹 𝗲𝗿𝗿𝗼𝗿</b></summary>

```bash
# Check disk usage
docker exec hls-relay df -h /root

# Check HLS segment usage
docker exec hls-relay du -sh /root/hls/*/

# Check log sizes
docker exec hls-relay du -sh /root/logs/
```

</details>

<details>
<summary><b>𝗣𝗲𝗿𝗺𝗶𝘀𝘀𝗶𝗼𝗻 𝗲𝗿𝗿𝗼𝗿𝘀</b></summary>

```bash
# Check nginx error log
docker exec hls-relay tail -30 /root/logs/nginx_error.log

# Fix permissions if needed
docker exec hls-relay chown -R hlsuser:hlsgroup /root/hls /root/logs
```

</details>

---

## 📋 𝗙𝗔𝗤

**Q: Does the Quick Tunnel URL change when the container restarts?**
> Yes. Each `cloudflared tunnel --url` session generates a new random subdomain.
> Use **Named Tunnel** mode for a permanent URL.

**Q: How many channels can it handle?**
> Tested with **100+ channels** simultaneously. The limit is CPU and network bandwidth.
> Each channel runs one FFmpeg process in copy mode (no re-encoding) so CPU usage is minimal.

**Q: Can I use it without a Cloudflare account?**
> Yes. `CF_TUNNEL_MODE=quick` requires **zero accounts**.
> You get a public HTTPS URL immediately.

**Q: Is re-encoding done?**
> No. FFmpeg runs in **stream copy mode** (`-c:v copy -c:a copy`).
> This means near-zero CPU usage per channel and no quality loss.

**Q: What M3U formats are supported?**
> Standard `#EXTM3U` / `#EXTINF` format.
> Supports HTTP, HTTPS source streams.
> RTMP and UDP sources require additional FFmpeg input flags.

**Q: Does it work on ARM (Raspberry Pi, Apple Silicon)?**
> Yes. The Dockerfile auto-detects architecture (`amd64` / `arm64` / `armhf`)
> and downloads the correct cloudflared binary.

**Q: What happens when a channel goes offline?**
> FFmpeg exits → monitor loop detects PID gone after **15 seconds** →
> auto-restart with lock file to prevent duplicate processes.

---

## 🔬 𝗧𝗲𝗰𝗵𝗻𝗶𝗰𝗮𝗹 𝗦𝘁𝗮𝗰𝗸

| Component | Purpose | Version |
|-----------|---------|---------|
| **Debian Bookworm Slim** | Base OS | `bookworm-slim` |
| **FFmpeg** | Stream copy + HLS segmentation | System latest |
| **FFprobe** | Audio track detection | System latest |
| **Nginx** | HLS segment delivery, rate limiting | System latest |
| **cloudflared** | Cloudflare Tunnel client | Auto-latest |
| **Bash** | Orchestration script | `5.x` |
| **logrotate** | Log size management | System latest |

---

## 📜 𝗖𝗵𝗮𝗻𝗴𝗲𝗹𝗼𝗴

<details open>
<summary><b>v2.1.0 — Cloudflare Tunnel Integration</b></summary>

```
+ Added cloudflared installation in Dockerfile (multi-arch)
+ Quick Tunnel mode: instant public URL, no account required
+ Named Tunnel mode: stable custom domain via token
+ Tunnel watchdog: auto-restarts cloudflared if it crashes
+ /tunnel JSON endpoint: machine-readable tunnel status
+ Web dashboard updated with live tunnel URL display
+ Real IP headers from Cloudflare in nginx
+ Tunnel URL auto-injected into restream playlist
+ write_tunnel_json helper for clean status reporting
```

</details>

<details>
<summary><b>v2.0.0 — All Bugs Fixed</b></summary>

```
! Fixed: -method PUT removed from local FFmpeg output (BUG-01)
! Fixed: Audio language structured output pipe-delimited (BUG-02)
! Fixed: Map args stored as separate arrays not word-split strings (BUG-03)
! Fixed: Post-launch FFmpeg PID validation (BUG-04)
! Fixed: Safe read_pid helper prevents kill -0 on invalid PIDs (BUG-05)
! Fixed: append_list removed from hls_flags (BUG-06)
! Fixed: Nginx alias/root conflict resolved (BUG-07)
! Fixed: M3U parser handles EOF without trailing newline (BUG-08)
+ Added: URL scheme validation (SSRF prevention)
+ Added: Nginx hlsuser non-root worker
+ Added: logrotate 10MB cap
+ Added: Parallel audio probing with MAX_PROBE_JOBS
+ Added: find replaces compgen in monitor loop
+ Added: EXIT/INT/TERM cleanup trap
+ Added: Lock file prevents duplicate FFmpeg on restart
+ Added: Three channel states: ACTIVE / STARTING / DOWN
+ Added: Playlist excludes unready channels
+ Added: Duplicate URL deduplication
+ Added: Disk space pre-flight check
+ Added: Reserved nginx path collision protection
+ Added: JSON stats written every monitor loop
```

</details>

---

## 🤝 𝗖𝗼𝗻𝘁𝗿𝗶𝗯𝘂𝘁𝗶𝗻𝗴

Contributions, bug reports, and feature requests are welcome!

```bash
# Fork → Clone → Branch → Change → PR
git checkout -b feature/your-feature-name
git commit -m "feat: add your feature"
git push origin feature/your-feature-name
```

---

## 📄 𝗟𝗶𝗰𝗲𝗻𝘀𝗲

```
MIT License — Copyright (c) 2024 Mohammad Kobir Shah

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

---

<div align="center">

![Footer](https://capsule-render.vercel.app/api?type=waving&color=0:0d1117,50:1a1f35,100:0d1117&height=120&section=footer&animation=fadeIn)

𝗠𝗮𝗱𝗲 𝘄𝗶𝘁𝗵 ❤️ 𝗯𝘆 [𝗠𝗼𝗵𝗮𝗺𝗺𝗮𝗱 𝗞𝗼𝗯𝗶𝗿 𝗦𝗵𝗮𝗵](https://github.com/MohammadKobirShah)

[![GitHub followers](https://img.shields.io/github/followers/MohammadKobirShah?style=social)](https://github.com/MohammadKobirShah)
[![GitHub stars](https://img.shields.io/github/stars/MohammadKobirShah/hls-restreamer?style=social)](https://github.com/MohammadKobirShah/hls-restreamer)

*𝗜𝗳 𝘁𝗵𝗶𝘀 𝗽𝗿𝗼𝗷𝗲𝗰𝘁 𝗵𝗲𝗹𝗽𝗲𝗱 𝘆𝗼𝘂, 𝗽𝗹𝗲𝗮𝘀𝗲 ⭐ 𝘀𝘁𝗮𝗿 𝗶𝘁 𝗼𝗻 𝗚𝗶𝘁𝗵𝘂𝗯!*

</div>
