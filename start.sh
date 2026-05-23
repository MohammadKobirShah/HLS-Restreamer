#!/usr/bin/env bash
# ============================================================
# Kobir Shah Multi-Channel HLS Restreamer
# Version: 2.1.2 — Railway Stable
# GitHub: https://github.com/MohammadKobirShah
#
# FIXES IN 2.1.2:
#   [FIX-T1] --protocol http2 moved AFTER "run" subcommand
#            (was before "run" causing cloudflared to print
#            help text and exit immediately)
#   [FIX-T2] Named tunnel: correct token flag order
#            cloudflared tunnel run --protocol http2 --token X
#   [FIX-T3] Nginx starts FIRST before any tunnel/FFmpeg work
#            so Railway health check passes within 5s
#   [FIX-T4] Health check endpoint responds immediately
#   [FIX-T5] All tunnel work fully non-blocking (background)
#   [FIX-T6] Container never exits on tunnel failure
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ============================================================
# Version
# ============================================================
readonly VERSION="2.1.2"
readonly SCRIPT_START=$(date +%s)

# ============================================================
# Configuration
# ============================================================
readonly PLAYLIST_FILE="/root/playlist.m3u"
readonly M3U_URL="${M3U_URL:-}"
readonly HLS_ROOT="/root/hls"
readonly NGINX_CONF="/root/nginx.conf"
readonly LOG_DIR="/root/logs"
readonly LOCKS_DIR="/root/locks"
readonly PROBE_DIR="/root/probe_results"
readonly MASTER_PLAYLIST="${HLS_ROOT}/master.m3u8"
readonly OUTPUT_PLAYLIST="/root/restream_playlist.m3u8"
readonly TUNNEL_JSON="${HLS_ROOT}/tunnel.json"
readonly STATS_JSON="${HLS_ROOT}/stats.json"
readonly STATUS_HTML="${HLS_ROOT}/status.html"

# Cloudflare tunnel
readonly CF_TUNNEL_MODE="${CF_TUNNEL_MODE:-quick}"
readonly CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
readonly CF_TUNNEL_LOG="${LOG_DIR}/cloudflared.log"
readonly CF_TUNNEL_PID="/root/cloudflared.pid"
readonly CF_TUNNEL_URL_FILE="/root/tunnel_url.txt"

# Public domain override (used when tunnel disabled)
readonly PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"

# Tuning
readonly MAX_PROBE_JOBS="${MAX_PROBE_JOBS:-8}"
readonly HLS_SEGMENT_DURATION=2
readonly HLS_LIST_SIZE=4
readonly STARTUP_WAIT_SECONDS=20
readonly RESTART_THRESHOLD=15
readonly MONITOR_INTERVAL=5
readonly MIN_DISK_MB_PER_CHANNEL=25

# Reserved nginx paths
readonly -a RESERVED_PATHS=(
    "health" "status" "stats" "tunnel"
    "master" "restream_playlist" "favicon" "robots"
)

# ============================================================
# Global state arrays
# ============================================================
declare -a DISPLAY_NAMES=()
declare -a URLS=()
declare -a FOLDER_NAMES=()
declare -a EXTINF_LINES=()
declare -a MAP_VIDEO=()
declare -a MAP_AUDIO=()
declare -a CHOSEN_LANGS=()

PUBLIC_URL="http://localhost:8080"

# ============================================================
# Logging
# ============================================================
log_info()  { echo "[$(date '+%H:%M:%S')] [INFO]  $*" >&2; }
log_warn()  { echo "[$(date '+%H:%M:%S')] [WARN]  $*" >&2; }
log_error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }
log_ok()    { echo "[$(date '+%H:%M:%S')] [OK]    $*" >&2; }
log_cf()    { echo "[$(date '+%H:%M:%S')] [TUNNEL] $*" >&2; }

# ============================================================
# Cleanup trap
# ============================================================
CLEANUP_DONE=0

cleanup() {
    [[ $CLEANUP_DONE -eq 1 ]] && return
    CLEANUP_DONE=1
    log_info "Shutdown signal received – cleaning up..."

    # Stop cloudflared
    if [[ -f "$CF_TUNNEL_PID" ]]; then
        local cf_pid
        cf_pid=$(cat "$CF_TUNNEL_PID" 2>/dev/null || true)
        if [[ "$cf_pid" =~ ^[1-9][0-9]*$ ]]; then
            kill -TERM "$cf_pid" 2>/dev/null || true
            log_info "Stopped cloudflared (PID $cf_pid)"
        fi
        rm -f "$CF_TUNNEL_PID"
    fi
    pkill -f "cloudflared" 2>/dev/null || true

    # Stop all FFmpeg
    for ch_dir in "${HLS_ROOT}"/*/; do
        [[ -d "$ch_dir" ]] || continue
        local pid_file="${ch_dir}.ffmpeg.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file" 2>/dev/null || true)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
            rm -f "$pid_file"
        fi
    done

    sleep 2
    pkill -9 -f "ffmpeg.*${HLS_ROOT}" 2>/dev/null || true

    # Stop nginx
    if [[ -f /root/nginx.pid ]]; then
        local np
        np=$(cat /root/nginx.pid 2>/dev/null || true)
        if [[ "$np" =~ ^[1-9][0-9]*$ ]]; then
            nginx -s quit -p /root/ -c "$NGINX_CONF" 2>/dev/null || true
            sleep 2
            kill -9 "$np" 2>/dev/null || true
        fi
    fi

    rm -f "${LOCKS_DIR}"/*.lock   2>/dev/null || true
    rm -f "${PROBE_DIR}"/*.result 2>/dev/null || true
    rm -f "$CF_TUNNEL_URL_FILE"   2>/dev/null || true

    write_tunnel_json "offline" "none" ""
    log_info "Cleanup complete."
}

trap cleanup EXIT INT TERM HUP

# ============================================================
# Write tunnel.json
# ============================================================
write_tunnel_json() {
    local status="$1"
    local type="$2"
    local url="$3"
    mkdir -p "$HLS_ROOT"
    cat > "$TUNNEL_JSON" <<JSON
{
  "status": "${status}",
  "type":   "${type}",
  "url":    "${url}",
  "mode":   "${CF_TUNNEL_MODE}",
  "generated": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
}

# ============================================================
# Write status.html
# ============================================================
write_status_html() {
    mkdir -p "$HLS_ROOT"
    cat > "${STATUS_HTML}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>Kobir Shah - HLS Relay</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:"Courier New",monospace;background:#080c1a;color:#c9d1d9;
       padding:30px;min-height:100vh}
  .wrap{max-width:960px;margin:0 auto}
  h1{color:#58a6ff;font-size:1.8em;margin-bottom:4px}
  .sub{color:#6e7681;margin-bottom:28px;font-size:.9em}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
         gap:12px;margin-bottom:28px}
  .card{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:16px}
  .card-label{color:#6e7681;font-size:.75em;text-transform:uppercase;letter-spacing:1px}
  .card-value{color:#58a6ff;font-size:1.4em;font-weight:bold;margin-top:4px;
              word-break:break-all}
  .green{color:#3fb950} .orange{color:#d29922} .red{color:#f85149}
  .links{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:28px}
  a.btn{display:inline-block;padding:8px 16px;border-radius:6px;text-decoration:none;
        font-size:.85em;background:#161b22;border:1px solid #30363d;color:#c9d1d9;
        transition:all .2s}
  a.btn:hover{border-color:#58a6ff;color:#58a6ff}
  .tbox{background:#0d1117;border:1px solid #21262d;border-radius:8px;
        padding:20px;margin-bottom:20px}
  .turl{color:#3fb950;font-size:1em;word-break:break-all;margin-top:8px}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;
       background:#3fb950;margin-right:6px;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  table{width:100%;border-collapse:collapse;margin-top:16px}
  th{text-align:left;color:#6e7681;font-size:.75em;text-transform:uppercase;
     padding:8px;border-bottom:1px solid #21262d}
  td{padding:8px;border-bottom:1px solid #161b22;font-size:.85em}
  .s-active{color:#3fb950} .s-starting{color:#d29922} .s-down{color:#f85149}
  footer{margin-top:40px;color:#6e7681;font-size:.8em;text-align:center;
         border-top:1px solid #21262d;padding-top:16px}
</style>
</head>
<body>
<div class="wrap">
  <h1><span class="dot" id="hd"></span>Kobir Shah HLS Relay</h1>
  <p class="sub">Multi-Channel Live Streaming + Cloudflare Tunnel v2.1.2</p>
  <div class="tbox">
    <div class="card-label">Cloudflare Tunnel URL</div>
    <div class="turl" id="turl">Loading...</div>
    <div style="color:#6e7681;font-size:.8em;margin-top:6px" id="ttype"></div>
  </div>
  <div class="cards">
    <div class="card">
      <div class="card-label">Total Channels</div>
      <div class="card-value" id="tot">--</div>
    </div>
    <div class="card">
      <div class="card-label">Active</div>
      <div class="card-value green" id="act">--</div>
    </div>
    <div class="card">
      <div class="card-label">Starting</div>
      <div class="card-value orange" id="sta">--</div>
    </div>
    <div class="card">
      <div class="card-label">Down</div>
      <div class="card-value red" id="dwn">--</div>
    </div>
    <div class="card">
      <div class="card-label">Uptime</div>
      <div class="card-value" id="upt">--</div>
    </div>
  </div>
  <div class="links">
    <a class="btn" href="/master.m3u8">Master Playlist</a>
    <a class="btn" href="/restream_playlist.m3u8">Restream Playlist</a>
    <a class="btn" href="/stats">Stats JSON</a>
    <a class="btn" href="/tunnel">Tunnel JSON</a>
    <a class="btn" href="/health">Health</a>
  </div>
  <table>
    <thead>
      <tr><th>#</th><th>Channel</th><th>State</th><th>Segments</th><th>Audio</th></tr>
    </thead>
    <tbody id="ctb">
      <tr><td colspan="5" style="color:#6e7681">Loading...</td></tr>
    </tbody>
  </table>
  <footer>
    Developer: <strong>Mohammad Kobir Shah</strong> &mdash;
    <a href="https://github.com/MohammadKobirShah" style="color:#58a6ff">
      github.com/MohammadKobirShah
    </a>
  </footer>
</div>
<script>
function loadStats(){
  fetch("/stats").then(function(r){return r.json();}).then(function(d){
    document.getElementById("tot").textContent=d.total_channels||"--";
    document.getElementById("act").textContent=d.active||"0";
    document.getElementById("sta").textContent=d.starting||"0";
    document.getElementById("dwn").textContent=d.down||"0";
    document.getElementById("upt").textContent=d.uptime||"--";
    var b=document.getElementById("ctb");
    var ch=d.channels||[];
    b.innerHTML="";
    if(ch.length===0){
      b.innerHTML="<tr><td colspan='5' style='color:#6e7681'>No channels yet</td></tr>";
      return;
    }
    ch.forEach(function(c,i){
      var sc="s-"+c.state;
      var sy=c.state==="active"?"● ":c.state==="starting"?"◑ ":"○ ";
      b.innerHTML+="<tr><td>"+(i+1)+"</td><td>"+c.name+"</td>"
        +"<td class='"+sc+"'>"+sy+c.state+"</td>"
        +"<td>"+c.segments+"</td><td>"+c.audio_lang+"</td></tr>";
    });
  }).catch(function(){});
}
function loadTunnel(){
  fetch("/tunnel").then(function(r){return r.json();}).then(function(d){
    var el=document.getElementById("turl");
    var mt=document.getElementById("ttype");
    var dot=document.getElementById("hd");
    if(d.url&&d.url!=="pending"&&d.url!==""){
      el.innerHTML="<a href='"+d.url+"' target='_blank' style='color:#3fb950'>"+d.url+"</a>";
      mt.textContent="Type: "+d.type+"  |  Status: "+d.status;
      dot.style.background="#3fb950";
    } else if(d.status==="starting"){
      el.textContent="Tunnel starting — please wait...";
      el.style.color="#d29922";
      dot.style.background="#d29922";
    } else {
      el.textContent="Tunnel unavailable ("+( d.status||"unknown")+")";
      el.style.color="#f85149";
      dot.style.background="#f85149";
    }
  }).catch(function(){
    document.getElementById("turl").textContent="Cannot reach /tunnel";
  });
}
loadStats(); loadTunnel();
setInterval(loadStats,8000); setInterval(loadTunnel,8000);
</script>
</body>
</html>
HTMLEOF
    log_info "Status dashboard written → ${STATUS_HTML}"
}

# ============================================================
# URL validation
# ============================================================
validate_url() {
    local url="$1"
    local label="${2:-URL}"
    if [[ -z "$url" ]]; then
        log_error "${label} is empty"
        return 1
    fi
    if [[ ! "$url" =~ ^https?:// ]]; then
        log_error "${label} must use http:// or https:// scheme"
        return 1
    fi
    return 0
}

# ============================================================
# Disk space check
# ============================================================
check_disk_space() {
    local required_mb="$1"
    local path="${2:-/root}"
    local available_mb
    available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
        log_warn "Could not determine disk space – continuing"
        return 0
    fi
    log_info "Disk: ${available_mb}MB available, ${required_mb}MB needed"
    if (( available_mb < required_mb )); then
        log_error "Insufficient disk: have ${available_mb}MB, need ${required_mb}MB"
        return 1
    fi
    return 0
}

# ============================================================
# Download playlist
# ============================================================
download_playlist() {
    [[ -z "$M3U_URL" ]] && return 0
    validate_url "$M3U_URL" "M3U_URL" || return 1
    log_info "Downloading playlist from: $M3U_URL"
    local attempt
    for attempt in 1 2 3; do
        if curl -fsSL \
            --connect-timeout 15 \
            --max-time 60 \
            --proto '=https,http' \
            -H "User-Agent: Mozilla/5.0 (compatible; HLS-Restreamer/2.1)" \
            "$M3U_URL" -o "$PLAYLIST_FILE"; then
            log_ok "Playlist downloaded ($(wc -l < "$PLAYLIST_FILE") lines)"
            return 0
        fi
        log_warn "Download attempt $attempt/3 failed – retrying..."
        sleep 3
    done
    log_error "Failed to download playlist"
    return 1
}

# ============================================================
# M3U parser
# ============================================================
parse_playlist() {
    local file="$1"
    local line extinf="" pending=0
    log_info "Parsing: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" ]]             && continue
        [[ "$line" == "#EXTM3U"* ]] && continue
        if [[ "$line" =~ ^#EXTINF: ]]; then
            extinf="$line"
            pending=1
            continue
        fi
        if [[ $pending -eq 1 && ! "$line" =~ ^# ]]; then
            local raw_name folder
            raw_name=$(echo "$extinf" | sed 's/.*,\s*//' | xargs 2>/dev/null || true)
            [[ -z "$raw_name" ]] && raw_name="Channel_$((${#DISPLAY_NAMES[@]} + 1))"
            folder=$(echo "$raw_name" \
                | tr '[:upper:]' '[:lower:]' \
                | tr -cd 'a-z0-9' \
                | cut -c1-30)
            [[ -z "$folder" ]] && folder="channel"
            DISPLAY_NAMES+=("$raw_name")
            URLS+=("$line")
            FOLDER_NAMES+=("$folder")
            EXTINF_LINES+=("$extinf")
            pending=0
            extinf=""
        elif [[ $pending -eq 1 && "$line" =~ ^#EXTINF: ]]; then
            extinf="$line"
            pending=1
        fi
    done < "$file"
    log_info "Parsed: ${#DISPLAY_NAMES[@]} channels"
}

# ============================================================
# Dedup URLs
# ============================================================
dedup_urls() {
    declare -A seen_urls=()
    local -a kn=() ku=() kf=() ke=()
    local i
    for i in "${!URLS[@]}"; do
        local url="${URLS[$i]}"
        if [[ -n "${seen_urls[$url]:-}" ]]; then
            log_warn "Duplicate URL skipped: '${DISPLAY_NAMES[$i]}'"
            continue
        fi
        seen_urls[$url]="${DISPLAY_NAMES[$i]}"
        kn+=("${DISPLAY_NAMES[$i]}")
        ku+=("${URLS[$i]}")
        kf+=("${FOLDER_NAMES[$i]}")
        ke+=("${EXTINF_LINES[$i]}")
    done
    DISPLAY_NAMES=("${kn[@]+"${kn[@]}"}")
    URLS=("${ku[@]+"${ku[@]}"}")
    FOLDER_NAMES=("${kf[@]+"${kf[@]}"}")
    EXTINF_LINES=("${ke[@]+"${ke[@]}"}")
    log_info "After dedup: ${#DISPLAY_NAMES[@]} unique channels"
}

# ============================================================
# Dedup folder names
# ============================================================
dedup_folders() {
    declare -A seen=()
    local i folder original counter
    for i in "${!FOLDER_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        original="$folder"
        counter=2
        local is_reserved=0
        for reserved in "${RESERVED_PATHS[@]}"; do
            if [[ "$folder" == "$reserved" ]]; then
                is_reserved=1; break
            fi
        done
        if [[ $is_reserved -eq 1 ]]; then
            folder="${folder}ch"
            log_warn "Reserved name conflict: '${original}' → '${folder}'"
            original="$folder"
        fi
        while [[ -n "${seen[$folder]:-}" ]]; do
            folder="${original}${counter}"
            ((counter++))
        done
        seen[$folder]=1
        FOLDER_NAMES[$i]="$folder"
    done
}

# ============================================================
# Audio probe — single channel
# ============================================================
probe_audio_track() {
    local url="$1"
    local folder="$2"
    local out_file="$3"
    local audio_info beng_idx="" hin_idx="" first_idx=""

    audio_info=$(timeout 15 ffprobe \
        -v error \
        -select_streams a \
        -show_entries "stream=index:stream_tags=language" \
        -of csv=p=0 \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -analyzeduration 1000000 \
        -probesize 1000000 \
        "$url" 2>/dev/null) || true

    if [[ -n "$audio_info" ]]; then
        while IFS=, read -r idx lang; do
            idx=$(echo "$idx"   | xargs 2>/dev/null || true)
            lang=$(echo "$lang" | xargs 2>/dev/null \
                | tr '[:upper:]' '[:lower:]' || true)
            [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]] && continue
            [[ -z "$first_idx" ]] && first_idx="$idx"
            [[ "$lang" =~ ^(ben|beng|bengali)$ ]] && beng_idx="$idx"
            [[ "$lang" =~ ^(hin|hindi)$ ]]         && hin_idx="$idx"
        done <<< "$audio_info"
    fi

    local chosen_idx chosen_lang
    if [[ -n "$beng_idx" ]]; then
        chosen_idx="$beng_idx"; chosen_lang="Bengali"
    elif [[ -n "$hin_idx" ]]; then
        chosen_idx="$hin_idx";  chosen_lang="Hindi"
    elif [[ -n "$first_idx" ]]; then
        chosen_idx="$first_idx"; chosen_lang="Default"
    else
        echo "Auto||" > "$out_file"
        return 0
    fi
    echo "${chosen_lang}|0:v:0|0:${chosen_idx}" > "$out_file"
}

# ============================================================
# Parallel audio probing
# ============================================================
probe_all_audio() {
    log_info "Probing audio in parallel (max ${MAX_PROBE_JOBS} jobs)..."
    log_info "Priority: Bengali → Hindi → Default"
    mkdir -p "$PROBE_DIR"
    rm -f "${PROBE_DIR}"/*.result 2>/dev/null || true

    local -a job_pids=()
    local i
    for i in "${!DISPLAY_NAMES[@]}"; do
        local out_file="${PROBE_DIR}/probe_${i}.result"
        if ! validate_url "${URLS[$i]}" \
                "'${DISPLAY_NAMES[$i]}'" 2>/dev/null; then
            echo "Auto||" > "$out_file"
            continue
        fi
        (probe_audio_track \
            "${URLS[$i]}" "${FOLDER_NAMES[$i]}" "$out_file") &
        job_pids+=($!)
        if (( ${#job_pids[@]} >= MAX_PROBE_JOBS )); then
            wait "${job_pids[0]}" 2>/dev/null || true
            job_pids=("${job_pids[@]:1}")
        fi
    done
    for pid in "${job_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    for i in "${!DISPLAY_NAMES[@]}"; do
        local out_file="${PROBE_DIR}/probe_${i}.result"
        local result lang video_map audio_map
        result=$(cat "$out_file" 2>/dev/null || echo "Auto||")
        lang="${result%%|*}"
        local rest="${result#*|}"
        video_map="${rest%%|*}"
        audio_map="${rest##*|}"
        CHOSEN_LANGS+=("$lang")
        MAP_VIDEO+=("$video_map")
        MAP_AUDIO+=("$audio_map")
        case "$lang" in
            Bengali) log_ok  "  ✓ [$((i+1))/${#DISPLAY_NAMES[@]}] ${FOLDER_NAMES[$i]} → Bengali (stream $audio_map)" ;;
            Hindi)   log_info "  ~ [$((i+1))/${#DISPLAY_NAMES[@]}] ${FOLDER_NAMES[$i]} → Hindi (stream $audio_map)" ;;
            Default) log_info "  - [$((i+1))/${#DISPLAY_NAMES[@]}] ${FOLDER_NAMES[$i]} → Default (stream $audio_map)" ;;
            *)       log_warn "  ! [$((i+1))/${#DISPLAY_NAMES[@]}] ${FOLDER_NAMES[$i]} → Auto-select" ;;
        esac
    done
    rm -f "${PROBE_DIR}"/*.result 2>/dev/null || true
    log_info "Audio probe done."
}

# ============================================================
# FFmpeg launcher
# ============================================================
start_ffmpeg() {
    local idx="$1"
    local folder="${FOLDER_NAMES[$idx]}"
    local url="${URLS[$idx]}"
    local name="${DISPLAY_NAMES[$idx]}"
    local ch_dir="${HLS_ROOT}/${folder}"
    local log_file="${LOG_DIR}/ffmpeg_${folder}.log"
    local pid_file="${ch_dir}/.ffmpeg.pid"

    mkdir -p "$ch_dir"
    find "$ch_dir" -maxdepth 1 \
        \( -name 'segment*.ts' -o -name '*.m3u8' \) \
        -delete 2>/dev/null || true

    local -a cmd=(
        ffmpeg -hide_banner -loglevel error -y
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 20
        -timeout 10000000
        -analyzeduration 1000000 -probesize 1000000
        -fflags "+genpts+discardcorrupt+nobuffer"
        -flags "low_delay"
        -user_agent \
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        -i "$url"
    )

    local v_map="${MAP_VIDEO[$idx]:-}"
    local a_map="${MAP_AUDIO[$idx]:-}"
    if [[ -n "$v_map" && -n "$a_map" ]]; then
        cmd+=(-map "$v_map" -map "$a_map")
    fi

    cmd+=(
        -c:v copy -c:a copy
        -copyts -start_at_zero
        -avoid_negative_ts make_zero
        -max_muxing_queue_size 2048
        -f hls
        -hls_time             "$HLS_SEGMENT_DURATION"
        -hls_list_size        "$HLS_LIST_SIZE"
        -hls_flags            "delete_segments+omit_endlist+independent_segments"
        -hls_segment_type     mpegts
        -hls_segment_filename "${ch_dir}/segment_%05d.ts"
        "${ch_dir}/${folder}.m3u8"
    )

    if [[ -f "$log_file" ]]; then
        local sz
        sz=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        (( sz > 10485760 )) && mv "$log_file" "${log_file}.1"
    fi

    nohup "${cmd[@]}" >> "$log_file" 2>&1 &
    local pid=$!

    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "FFmpeg for '$name' died immediately – see: $log_file"
        rm -f "$pid_file"
        return 1
    fi

    echo "$pid" > "$pid_file"
    log_info "FFmpeg started: '$name' (PID $pid → $folder)"
    return 0
}

# ============================================================
# PID helpers
# ============================================================
read_pid() {
    local pid_file="$1"
    [[ ! -f "$pid_file" ]] && return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || return 1
    [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] && return 1
    echo "$pid"
}

is_ffmpeg_running() {
    local ch_dir="$1"
    local pid
    pid=$(read_pid "${ch_dir}/.ffmpeg.pid") || return 1
    kill -0 "$pid" 2>/dev/null
}

# ============================================================
# Playlist generators
# ============================================================
generate_master_playlist() {
    local included=0
    {
        echo "#EXTM3U"
        echo "#PLAYLIST:Kobir Shah Multi-Channel HLS v${VERSION}"
        echo "#GENERATED:$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        for i in "${!DISPLAY_NAMES[@]}"; do
            local folder="${FOLDER_NAMES[$i]}"
            local ch_dir="${HLS_ROOT}/${folder}"
            if find "$ch_dir" -maxdepth 1 -name 'segment*.ts' \
                    -quit 2>/dev/null | grep -q . || \
               [[ -f "${ch_dir}/${folder}.m3u8" ]]; then
                echo "${EXTINF_LINES[$i]}"
                echo "http://localhost:8080/${folder}/${folder}.m3u8"
                ((included++))
            else
                echo "# NOT READY: ${EXTINF_LINES[$i]}"
            fi
        done
    } > "$MASTER_PLAYLIST"
}

generate_restream_playlist() {
    local pub_url="${1:-$PUBLIC_URL}"
    local included=0
    {
        echo "#EXTM3U"
        echo "#PLAYLIST:Kobir Shah Restream v${VERSION}"
        echo "#GENERATED:$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "#TUNNEL_URL:${pub_url}"
        echo ""
        for i in "${!DISPLAY_NAMES[@]}"; do
            local folder="${FOLDER_NAMES[$i]}"
            local ch_dir="${HLS_ROOT}/${folder}"
            if find "$ch_dir" -maxdepth 1 -name 'segment*.ts' \
                    -quit 2>/dev/null | grep -q . || \
               [[ -f "${ch_dir}/${folder}.m3u8" ]]; then
                echo "${EXTINF_LINES[$i]}"
                echo "${pub_url}/${folder}/${folder}.m3u8"
                ((included++))
            else
                echo "# UNAVAILABLE: ${DISPLAY_NAMES[$i]}"
            fi
        done
        echo ""
        echo "# Total: ${#DISPLAY_NAMES[@]} | Available: ${included}"
    } > "$OUTPUT_PLAYLIST"
}

# ============================================================
# Write JSON stats
# ============================================================
write_stats() {
    local active_count="$1"
    local starting_count="$2"
    local down_count="$3"
    local uptime_s=$(( $(date +%s) - SCRIPT_START ))
    local h=$(( uptime_s / 3600 ))
    local m=$(( (uptime_s % 3600) / 60 ))
    local s=$(( uptime_s % 60 ))
    local uptime_str
    printf -v uptime_str "%02dh%02dm%02ds" "$h" "$m" "$s"

    local tunnel_url="" tunnel_status="disabled" tunnel_type="none"
    if [[ -f "$TUNNEL_JSON" ]]; then
        tunnel_url=$(grep -oP '"url":\s*"\K[^"]+' \
            "$TUNNEL_JSON" 2>/dev/null || true)
        tunnel_status=$(grep -oP '"status":\s*"\K[^"]+' \
            "$TUNNEL_JSON" 2>/dev/null || true)
        tunnel_type=$(grep -oP '"type":\s*"\K[^"]+' \
            "$TUNNEL_JSON" 2>/dev/null || true)
    fi

    {
        echo "{"
        echo "  \"version\": \"${VERSION}\","
        echo "  \"generated\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
        echo "  \"uptime\": \"${uptime_str}\","
        echo "  \"uptime_seconds\": ${uptime_s},"
        echo "  \"total_channels\": ${#DISPLAY_NAMES[@]},"
        echo "  \"active\": ${active_count},"
        echo "  \"starting\": ${starting_count},"
        echo "  \"down\": ${down_count},"
        echo "  \"public_url\": \"${PUBLIC_URL}\","
        echo "  \"tunnel\": {"
        echo "    \"status\": \"${tunnel_status}\","
        echo "    \"type\": \"${tunnel_type}\","
        echo "    \"url\": \"${tunnel_url}\""
        echo "  },"
        echo "  \"channels\": ["
        local first=1
        for i in "${!DISPLAY_NAMES[@]}"; do
            local folder="${FOLDER_NAMES[$i]}"
            local ch_dir="${HLS_ROOT}/${folder}"
            local lang="${CHOSEN_LANGS[$i]:-Auto}"
            local seg_count state
            seg_count=$(find "$ch_dir" -maxdepth 1 \
                -name 'segment*.ts' -printf '.' 2>/dev/null | wc -c)
            if is_ffmpeg_running "$ch_dir"; then
                state="active"
            elif [[ -f "${LOCKS_DIR}/${folder}.lock" ]]; then
                state="starting"
            else
                state="down"
            fi
            local safe_name="${DISPLAY_NAMES[$i]//\"/\\\"}"
            [[ $first -eq 0 ]] && echo "    ,"
            echo "    {"
            echo "      \"index\": ${i},"
            echo "      \"name\": \"${safe_name}\","
            echo "      \"folder\": \"${folder}\","
            echo "      \"url\": \"${PUBLIC_URL}/${folder}/${folder}.m3u8\","
            echo "      \"state\": \"${state}\","
            echo "      \"audio_lang\": \"${lang}\","
            echo "      \"segments\": ${seg_count}"
            echo "    }"
            first=0
        done
        echo "  ]"
        echo "}"
    } > "$STATS_JSON"
}

# ============================================================
# Cloudflare Quick Tunnel
#
# FIX-T1: --protocol http2 is placed AFTER the tunnel subcommand
#         cloudflared tunnel --no-autoupdate \
#                     [global flags] \
#                     [subcommand: (no subcommand for --url mode)]
#
# For quick tunnel (--url mode) the correct form is:
#   cloudflared tunnel --no-autoupdate --protocol http2 --url URL
# The --protocol flag IS a global tunnel flag for --url mode.
#
# For named tunnel (run --token) the correct form is:
#   cloudflared tunnel --no-autoupdate run --protocol http2 --token TOKEN
# The --protocol flag comes AFTER run for the run subcommand.
# ============================================================
start_quick_tunnel() {
    log_cf "Starting Cloudflare Quick Tunnel..."
    log_cf "Using --protocol http2 (TCP, Railway-compatible)"
    write_tunnel_json "starting" "quick" "pending"

    pkill -f "cloudflared" 2>/dev/null || true
    sleep 1
    rm -f "$CF_TUNNEL_PID"
    : > "$CF_TUNNEL_LOG"

    # For quick tunnel (--url mode), --protocol is a global flag
    # placed before the url argument, not after a subcommand
    cloudflared tunnel \
        --no-autoupdate \
        --protocol http2 \
        --url "http://localhost:8080" \
        --logfile "$CF_TUNNEL_LOG" \
        --loglevel info \
        >> "$CF_TUNNEL_LOG" 2>&1 &

    local cf_pid=$!
    echo "$cf_pid" > "$CF_TUNNEL_PID"
    log_cf "cloudflared quick tunnel PID $cf_pid"

    # Extract tunnel URL from log (up to 90 seconds)
    local url="" waited=0 max_wait=90
    log_cf "Waiting for tunnel URL (up to ${max_wait}s)..."

    while [[ -z "$url" ]] && (( waited < max_wait )); do
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            log_warn "cloudflared quick tunnel exited early"
            log_warn "Last log output:"
            tail -15 "$CF_TUNNEL_LOG" >&2
            write_tunnel_json "error" "quick" ""
            return 0
        fi

        url=$(grep -oP \
            'https://[a-zA-Z0-9\-]+\.trycloudflare\.com' \
            "$CF_TUNNEL_LOG" 2>/dev/null | tail -1 || true)

        [[ -n "$url" ]] && break
        sleep 3
        (( waited += 3 ))
    done

    if [[ -z "$url" ]]; then
        log_warn "Quick tunnel URL not detected in ${max_wait}s"
        tail -20 "$CF_TUNNEL_LOG" >&2
        write_tunnel_json "error" "quick" ""
        return 0
    fi

    echo "$url" > "$CF_TUNNEL_URL_FILE"
    write_tunnel_json "online" "quick" "$url"
    PUBLIC_URL="$url"

    log_ok "╔══════════════════════════════════════════════════════╗"
    log_ok "║  Cloudflare Quick Tunnel LIVE                        ║"
    log_ok "║  URL:      ${url}"
    log_ok "║  Playlist: ${url}/restream_playlist.m3u8"
    log_ok "║  Status:   ${url}/status"
    log_ok "╚══════════════════════════════════════════════════════╝"

    return 0
}

# ============================================================
# Cloudflare Named Tunnel
#
# FIX-T2: --protocol http2 placed AFTER "run" subcommand
#   WRONG: cloudflared tunnel --protocol http2 run --token X
#   RIGHT: cloudflared tunnel run --protocol http2 --token X
# ============================================================
start_named_tunnel() {
    log_cf "Starting Cloudflare Named Tunnel..."

    if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
        log_error "CF_TUNNEL_TOKEN is required for named tunnel mode"
        log_error "Get token from: https://one.dash.cloudflare.com → Networks → Tunnels"
        write_tunnel_json "error" "named" ""
        return 0
    fi

    if [[ ${#CF_TUNNEL_TOKEN} -lt 50 ]]; then
        log_error "CF_TUNNEL_TOKEN appears invalid (too short: ${#CF_TUNNEL_TOKEN} chars)"
        write_tunnel_json "error" "named" ""
        return 0
    fi

    write_tunnel_json "starting" "named" "pending"

    pkill -f "cloudflared" 2>/dev/null || true
    sleep 1
    rm -f "$CF_TUNNEL_PID"
    : > "$CF_TUNNEL_LOG"

    # FIX-T2: --protocol http2 comes AFTER the "run" subcommand
    # This is the correct argument order for named tunnel token auth
    cloudflared tunnel \
        --no-autoupdate \
        run \
        --protocol http2 \
        --token "$CF_TUNNEL_TOKEN" \
        --logfile "$CF_TUNNEL_LOG" \
        --loglevel info \
        >> "$CF_TUNNEL_LOG" 2>&1 &

    local cf_pid=$!
    echo "$cf_pid" > "$CF_TUNNEL_PID"
    log_cf "cloudflared named tunnel PID $cf_pid"

    # Wait for connection confirmation
    local waited=0 max_wait=60 connected=0
    log_cf "Waiting for named tunnel connection (up to ${max_wait}s)..."

    while (( waited < max_wait )); do
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            log_warn "cloudflared named tunnel exited early"
            log_warn "Last log output:"
            tail -15 "$CF_TUNNEL_LOG" >&2
            write_tunnel_json "error" "named" ""
            return 0
        fi

        if grep -q \
            -e "Connection registered" \
            -e "Registered tunnel connection" \
            -e "Tunnel is ready" \
            -e "conns=4" \
            "$CF_TUNNEL_LOG" 2>/dev/null; then
            connected=1
            break
        fi

        sleep 2
        (( waited += 2 ))
    done

    local named_url=""
    [[ -n "$PUBLIC_DOMAIN" ]] && named_url="${PUBLIC_DOMAIN%/}"

    if [[ $connected -eq 1 ]]; then
        write_tunnel_json "online" "named" "$named_url"
        [[ -n "$named_url" ]] && PUBLIC_URL="$named_url"
        log_ok "Named tunnel connected → ${named_url:-check Cloudflare dashboard}"
    else
        log_warn "Named tunnel not confirmed in ${max_wait}s – may still be connecting"
        write_tunnel_json "starting" "named" "${named_url}"
    fi

    return 0
}

# ============================================================
# Tunnel watchdog — restarts cloudflared if it dies
# Uses exponential backoff: 30s → 60s → 120s → max 300s
# ============================================================
tunnel_watchdog() {
    local mode="$1"
    local backoff=30
    log_cf "Tunnel watchdog started (mode: $mode)"

    while true; do
        sleep "$backoff"

        [[ ! -f "$CF_TUNNEL_PID" ]] && break

        local cf_pid
        cf_pid=$(cat "$CF_TUNNEL_PID" 2>/dev/null || true)
        [[ ! "$cf_pid" =~ ^[1-9][0-9]*$ ]] && break

        if ! kill -0 "$cf_pid" 2>/dev/null; then
            log_cf "Watchdog: cloudflared down – restarting (backoff ${backoff}s)..."
            write_tunnel_json "starting" "$mode" "pending"

            if [[ "$mode" == "quick" ]]; then
                start_quick_tunnel || true
            elif [[ "$mode" == "named" ]]; then
                start_named_tunnel || true
            fi

            if (( ${#DISPLAY_NAMES[@]} > 0 )); then
                generate_restream_playlist "$PUBLIC_URL" 2>/dev/null || true
                generate_master_playlist                 2>/dev/null || true
            fi

            (( backoff = backoff * 2 ))
            (( backoff > 300 )) && backoff=300
        else
            # Process alive — check for newly appeared URL (quick tunnel)
            if [[ "$mode" == "quick" && -f "$CF_TUNNEL_LOG" ]]; then
                local new_url
                new_url=$(grep -oP \
                    'https://[a-zA-Z0-9\-]+\.trycloudflare\.com' \
                    "$CF_TUNNEL_LOG" 2>/dev/null | tail -1 || true)
                if [[ -n "$new_url" && "$new_url" != "$PUBLIC_URL" ]]; then
                    log_cf "Tunnel URL updated: $new_url"
                    PUBLIC_URL="$new_url"
                    write_tunnel_json "online" "quick" "$new_url"
                    generate_restream_playlist "$PUBLIC_URL" 2>/dev/null || true
                fi
            fi
            backoff=30
        fi
    done

    log_cf "Tunnel watchdog exiting"
}

# ============================================================
# Post-startup background worker
# Runs segment wait + playlist generation without blocking
# the monitor loop (which keeps health check green)
# ============================================================
post_startup_worker() {
    log_info "Post-startup: waiting ${STARTUP_WAIT_SECONDS}s for segments..."
    sleep "$STARTUP_WAIT_SECONDS"

    generate_master_playlist
    generate_restream_playlist "$PUBLIC_URL"

    local dead_count=0
    for i in "${!DISPLAY_NAMES[@]}"; do
        local ch_dir="${HLS_ROOT}/${FOLDER_NAMES[$i]}"
        if ! find "$ch_dir" -maxdepth 1 -name 'segment*.ts' \
                -quit 2>/dev/null | grep -q .; then
            log_warn "No segments yet: ${DISPLAY_NAMES[$i]}"
            (( dead_count++ ))
        fi
    done

    if (( dead_count == 0 )); then
        log_ok "All channels producing segments"
    else
        log_warn "${dead_count} channel(s) have no segments after ${STARTUP_WAIT_SECONDS}s"
    fi
}

# ============================================================
# Color setup
# ============================================================
setup_colors() {
    if [[ -t 2 ]]; then
        RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
        BLUE='\033[0;34m' CYAN='\033[0;36m'   WHITE='\033[1;37m'
        BOLD='\033[1m'    DIM='\033[2m'        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
        WHITE='' BOLD='' DIM='' NC=''
    fi
}

# ============================================================
# ============================================================
# MAIN
# ============================================================
# ============================================================

setup_colors

mkdir -p "$HLS_ROOT" "$LOG_DIR" "$LOCKS_DIR" "$PROBE_DIR"
chmod 755 /root "$HLS_ROOT" "$LOG_DIR" "$LOCKS_DIR" "$PROBE_DIR"

# Write static files before anything else
write_status_html
write_tunnel_json "starting" "${CF_TUNNEL_MODE}" "pending"

log_info "=================================================="
log_info " Kobir Shah HLS Restreamer v${VERSION}"
log_info " Tunnel mode: ${CF_TUNNEL_MODE}"
log_info "=================================================="

# Kill stale processes
log_info "Stopping stale processes..."
pkill -f "cloudflared"          2>/dev/null || true
pkill -f "ffmpeg.*${HLS_ROOT}"  2>/dev/null || true
pkill -x nginx                  2>/dev/null || true
sleep 2
rm -f /root/nginx.pid "${LOCKS_DIR}"/*.lock "$CF_TUNNEL_PID" 2>/dev/null || true

# Validate nginx config FIRST — fail fast before any download
log_info "Validating nginx config..."
if ! nginx -t -c "$NGINX_CONF" -p /root/ 2>>"${LOG_DIR}/nginx.log"; then
    log_error "Nginx config invalid – fix nginx.conf and rebuild"
    tail -20 "${LOG_DIR}/nginx.log" >&2
    exit 1
fi
log_ok "Nginx config valid"

# FIX-T3: Start nginx FIRST so health check passes immediately
log_info "Starting nginx..."
nginx -c "$NGINX_CONF" -p /root/ >> "${LOG_DIR}/nginx.log" 2>&1

nginx_up=0
for i in $(seq 1 20); do
    if ss -tlnp 2>/dev/null | grep -q ':8080'; then
        nginx_up=1
        break
    fi
    sleep 1
done

if [[ $nginx_up -eq 0 ]]; then
    log_error "Nginx failed to bind to :8080"
    tail -20 "${LOG_DIR}/nginx_error.log" >&2
    exit 1
fi
log_ok "Nginx listening on :8080 — health check will now pass"

# Write initial stats so /stats doesn't 404
write_stats 0 0 0 2>/dev/null || true

# Download playlist
download_playlist || exit 1

if [[ ! -f "$PLAYLIST_FILE" ]]; then
    log_error "Playlist not found: $PLAYLIST_FILE"
    exit 1
fi

# Parse + dedup
parse_playlist "$PLAYLIST_FILE"

if [[ ${#DISPLAY_NAMES[@]} -eq 0 ]]; then
    log_error "No channels parsed from $PLAYLIST_FILE"
    exit 1
fi

dedup_urls
dedup_folders

log_info "${#DISPLAY_NAMES[@]} unique channels ready to stream"

# Disk check
check_disk_space \
    $(( ${#DISPLAY_NAMES[@]} * MIN_DISK_MB_PER_CHANNEL + 300 )) \
    "/root" || exit 1

# Parallel audio probe
probe_all_audio

# Start Cloudflare tunnel (non-blocking — never causes exit)
case "$CF_TUNNEL_MODE" in
    quick)
        if command -v cloudflared &>/dev/null; then
            start_quick_tunnel
            tunnel_watchdog "quick" &
        else
            log_error "cloudflared binary not found in PATH"
            write_tunnel_json "error" "quick" ""
        fi
        ;;
    named)
        if command -v cloudflared &>/dev/null; then
            start_named_tunnel
            tunnel_watchdog "named" &
        else
            log_error "cloudflared binary not found in PATH"
            write_tunnel_json "error" "named" ""
        fi
        ;;
    disabled)
        log_info "Cloudflare tunnel disabled"
        write_tunnel_json "disabled" "none" ""
        [[ -n "$PUBLIC_DOMAIN" ]] && PUBLIC_URL="${PUBLIC_DOMAIN%/}"
        ;;
    *)
        log_warn "Unknown CF_TUNNEL_MODE='${CF_TUNNEL_MODE}' – defaulting to quick"
        start_quick_tunnel
        tunnel_watchdog "quick" &
        ;;
esac

# Launch FFmpeg for all channels
log_info "Launching ${#DISPLAY_NAMES[@]} FFmpeg instances..."
for i in "${!DISPLAY_NAMES[@]}"; do
    start_ffmpeg "$i" || true
    sleep 0.3
done

# Post-startup worker runs in background (non-blocking)
post_startup_worker &

log_ok "System running. Monitor loop starting..."

# ============================================================
# Monitor loop
# ============================================================
loop_count=0

while true; do
    printf '\033[H\033[2J' 2>/dev/null || clear

    local_time=$(date '+%Y-%m-%d %H:%M:%S')
    uptime_s=$(( $(date +%s) - SCRIPT_START ))
    uptime_str=$(printf "%02dh %02dm %02ds" \
        $((uptime_s/3600)) \
        $(( (uptime_s%3600)/60 )) \
        $((uptime_s%60)))

    tunnel_url=""
    tunnel_status=""
    if [[ -f "$TUNNEL_JSON" ]]; then
        tunnel_url=$(grep -oP '"url":\s*"\K[^"]+' \
            "$TUNNEL_JSON" 2>/dev/null || true)
        tunnel_status=$(grep -oP '"status":\s*"\K[^"]+' \
            "$TUNNEL_JSON" 2>/dev/null || true)
    fi

    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}     KOBIR SHAH – HLS RESTREAMER v${VERSION} + CLOUDFLARE TUNNEL         ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    case "$tunnel_status" in
        online)   echo -e "  ${BOLD}☁  Tunnel:${NC}  ${GREEN}LIVE${NC} → ${GREEN}${tunnel_url}${NC}" ;;
        starting) echo -e "  ${BOLD}☁  Tunnel:${NC}  ${YELLOW}CONNECTING...${NC}" ;;
        disabled) echo -e "  ${BOLD}☁  Tunnel:${NC}  ${DIM}Disabled${NC}" ;;
        error)    echo -e "  ${BOLD}☁  Tunnel:${NC}  ${RED}ERROR – watchdog will retry${NC}" ;;
        offline)  echo -e "  ${BOLD}☁  Tunnel:${NC}  ${RED}OFFLINE${NC}" ;;
        *)        echo -e "  ${BOLD}☁  Tunnel:${NC}  ${DIM}${tunnel_status:-unknown}${NC}" ;;
    esac

    echo -e "  ${BOLD}Local:${NC}     ${CYAN}http://localhost:8080${NC}"
    echo -e "  ${BOLD}Playlist:${NC}  ${CYAN}${PUBLIC_URL}/restream_playlist.m3u8${NC}"
    echo -e "  ${BOLD}Dashboard:${NC} ${CYAN}${PUBLIC_URL}/status${NC}"
    echo -e "  ${BOLD}Channels:${NC}  ${WHITE}${#DISPLAY_NAMES[@]}${NC}"
    echo -e "  ${BOLD}Time:${NC}      ${DIM}${local_time}${NC}  │  Up: ${uptime_str}"
    echo ""

    printf "${BOLD}  %-3s %-26s %-11s %-5s %-10s %-10s${NC}\n" \
        "#" "CHANNEL" "STATE" "SEGS" "UPDATED" "AUDIO"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${NC}"

    declare -i active_count=0 starting_count=0 down_count=0

    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        name="${DISPLAY_NAMES[$i]}"
        ch_dir="${HLS_ROOT}/${folder}"
        playlist="${ch_dir}/${folder}.m3u8"
        lang="${CHOSEN_LANGS[$i]:-Auto}"
        lock_file="${LOCKS_DIR}/${folder}.lock"

        seg_count=$(find "$ch_dir" -maxdepth 1 \
            -name 'segment*.ts' -printf '.' 2>/dev/null | wc -c)

        if [[ -f "$playlist" ]]; then
            age=$(( $(date +%s) - $(stat -c %Y "$playlist" \
                2>/dev/null || date +%s) ))
            if   (( age < 60 ));   then updated="${age}s ago"
            elif (( age < 3600 )); then updated="$((age/60))m ago"
            else                        updated="${RED}STALE${NC}"
            fi
        else
            updated="waiting"
        fi

        if is_ffmpeg_running "$ch_dir"; then
            state="${GREEN}● ACTIVE${NC}"
            ((active_count++))
            rm -f "${ch_dir}/.down_since"

        elif [[ -f "$lock_file" ]]; then
            state="${YELLOW}● STARTING${NC}"
            ((starting_count++))
            seg_count=0
            updated="restarting"

        else
            state="${RED}● DOWN${NC}"
            ((down_count++))

            if [[ ! -f "${ch_dir}/.down_since" ]]; then
                date +%s > "${ch_dir}/.down_since"
            fi

            local down_since
            down_since=$(cat "${ch_dir}/.down_since" \
                2>/dev/null || date +%s)
            local down_time=$(( $(date +%s) - down_since ))

            if (( down_time >= RESTART_THRESHOLD )); then
                if [[ ! -f "$lock_file" ]]; then
                    touch "$lock_file"
                    rm -f "${ch_dir}/.down_since"
                    state="${YELLOW}● RESTART${NC}"
                    (
                        start_ffmpeg "$i" || true
                        rm -f "$lock_file"
                    ) &
                fi
            fi
        fi

        case "$lang" in
            Bengali) lc="${GREEN}${lang}${NC}" ;;
            Hindi)   lc="${BLUE}${lang}${NC}"  ;;
            Default) lc="${CYAN}${lang}${NC}"  ;;
            *)       lc="${YELLOW}${lang}${NC}" ;;
        esac

        if (( ${#name} > 24 )); then
            short_name="${name:0:22}.."
        else
            short_name="$name"
        fi

        printf "  %-3s %-26s %b  %-5s %-10s %b\n" \
            "$((i+1))" "$short_name" \
            "$state" "$seg_count" "$updated" "$lc"
    done

    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}● Active: ${active_count}${NC}   " \
            "${YELLOW}◑ Starting: ${starting_count}${NC}   " \
            "${RED}○ Down: ${down_count}${NC}"
    echo ""
    echo -e "  ${GREEN}● Bengali${NC}  ${BLUE}● Hindi${NC}  " \
            "${CYAN}● Default${NC}  ${YELLOW}● Auto${NC}"
    echo ""
    echo -e "  ${DIM}Tunnel: ${CF_TUNNEL_MODE} │ Logs: ${LOG_DIR} │ " \
            "Refresh: ${MONITOR_INTERVAL}s │ Ctrl+C to stop${NC}"

    # Periodic tasks
    write_stats "$active_count" "$starting_count" "$down_count" \
        2>/dev/null || true

    if (( loop_count % 6 == 0 )); then
        generate_master_playlist                 2>/dev/null || true
        generate_restream_playlist "$PUBLIC_URL" 2>/dev/null || true
    fi

    if (( loop_count % 60 == 0 && loop_count > 0 )); then
        logrotate -s /root/logs/logrotate.state \
            /etc/logrotate.d/hls-restreamer 2>/dev/null || true
    fi

    ((loop_count++))
    sleep "$MONITOR_INTERVAL"
done
