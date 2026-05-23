#!/usr/bin/env bash
#
# Multi-channel HLS restreamer – Production-Ready Edition
# Developer: Kobir Shah
# Optimized for: Low latency, minimal buffering, maximum stability
#

set -euo pipefail
IFS=$'\n\t'

# ========================================
# Configuration
# ========================================
PLAYLIST_FILE="/root/playlist.m3u"
M3U_URL="${M3U_URL:-}"
HLS_ROOT="/root/hls"
NGINX_CONF="/root/nginx.conf"
LOG_DIR="/root/logs"
MASTER_PLAYLIST="${HLS_ROOT}/master.m3u8"
OUTPUT_PLAYLIST="/root/restream_playlist.m3u8"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
RESTART_THRESHOLD=15
MAX_RETRIES=3

mkdir -p "$HLS_ROOT" "$LOG_DIR"
chmod 755 /root "$HLS_ROOT" "$LOG_DIR"

# ========================================
# Logging helpers
# ========================================
log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ========================================
# Download remote playlist
# ========================================
if [[ -n "$M3U_URL" ]]; then
    log_info "Downloading playlist from $M3U_URL"
    for i in {1..3}; do
        if curl -fsSL --connect-timeout 10 --max-time 30 \
            -H "User-Agent: Mozilla/5.0" \
            "$M3U_URL" -o "$PLAYLIST_FILE"; then
            log_info "Playlist downloaded successfully"
            break
        else
            log_warn "Download attempt $i failed"
            sleep 2
        fi
    done
    
    if [[ ! -f "$PLAYLIST_FILE" ]]; then
        log_error "Failed to download playlist after 3 attempts"
        exit 1
    fi
fi

# ========================================
# Pre-flight checks
# ========================================
if [[ ! -f "$PLAYLIST_FILE" ]]; then
    log_error "Playlist not found: $PLAYLIST_FILE"
    log_error "Either mount a local file or set M3U_URL environment variable"
    exit 1
fi

if [[ ! -f "$NGINX_CONF" ]]; then
    log_error "Nginx config not found: $NGINX_CONF"
    exit 1
fi

# ========================================
# Cleanup existing processes
# ========================================
log_info "Cleaning up existing processes..."
pkill -f "ffmpeg.*${HLS_ROOT}" 2>/dev/null || true
pkill -x nginx 2>/dev/null || true
sleep 2

# Remove stale pid files
rm -f /root/nginx.pid /root/*.pid

# ========================================
# Parse M3U playlist
# ========================================
declare -a DISPLAY_NAMES=()
declare -a URLS=()
declare -a FOLDER_NAMES=()
declare -a EXTINF_LINES=()

log_info "Parsing $PLAYLIST_FILE"

while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r\n')
    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^#EXTINF: ]]; then
        extinf="$line"
        display_name=$(echo "$line" | sed -n 's/.*,\s*\(.*\)$/\1/p' | xargs)
        
        # Read next non-empty line as URL
        while IFS= read -r url; do
            url=$(echo "$url" | tr -d '\r\n' | xargs)
            [[ -n "$url" && ! "$url" =~ ^# ]] && break
        done
        
        if [[ -z "$url" || "$url" =~ ^# ]]; then
            log_warn "Skipping channel '$display_name' - no valid URL"
            continue
        fi
        
        # Generate safe folder name
        foldername=$(echo "$display_name" | tr '[:upper:]' '[:lower:]' | \
                     tr -cd 'a-z0-9' | cut -c1-30)
        [[ -z "$foldername" ]] && foldername="channel"
        
        DISPLAY_NAMES+=("$display_name")
        URLS+=("$url")
        FOLDER_NAMES+=("$foldername")
        EXTINF_LINES+=("$extinf")
    fi
done < "$PLAYLIST_FILE"

if [ ${#DISPLAY_NAMES[@]} -eq 0 ]; then
    log_error "No valid channels found in $PLAYLIST_FILE"
    exit 1
fi

log_info "Found ${#DISPLAY_NAMES[@]} channels"

# ========================================
# Deduplicate folder names
# ========================================
declare -A FOLDER_SEEN=()
for i in "${!FOLDER_NAMES[@]}"; do
    folder="${FOLDER_NAMES[$i]}"
    original="$folder"
    counter=1
    
    while [[ -n "${FOLDER_SEEN[$folder]:-}" ]]; do
        folder="${original}${counter}"
        ((counter++))
    done
    
    FOLDER_SEEN[$folder]=1
    FOLDER_NAMES[$i]="$folder"
done

# ========================================
# Audio track detection
# ========================================
declare -a MAP_ARGS=()
declare -a CHOSEN_LANGS=()

probe_audio_track() {
    local url="$1"
    local folder="$2"
    
    local audio_info
    audio_info=$(timeout 15 ffprobe -v error \
        -select_streams a \
        -show_entries stream=index:stream_tags=language \
        -of csv=p=0 \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -analyzeduration 3000000 -probesize 3000000 \
        "$url" 2>/dev/null) || true
    
    local chosen_idx=""
    local chosen_lang="Auto"
    local beng_idx=""
    local hin_idx=""
    local first_idx=""
    
    if [[ -n "$audio_info" ]]; then
        while IFS=, read -r idx lang; do
            idx=$(echo "$idx" | xargs)
            lang=$(echo "$lang" | xargs | tr '[:upper:]' '[:lower:]')
            
            [[ -z "$idx" ]] && continue
            
            if [[ -z "$first_idx" ]]; then
                first_idx="$idx"
            fi
            
            if [[ "$lang" =~ ^(ben|beng|bengali)$ ]]; then
                beng_idx="$idx"
            elif [[ "$lang" =~ ^(hin|hindi)$ ]]; then
                hin_idx="$idx"
            fi
        done <<< "$audio_info"
    fi
    
    if [[ -n "$beng_idx" ]]; then
        chosen_idx="$beng_idx"
        chosen_lang="Bengali"
        log_info "  ✓ $folder: Bengali audio (stream $beng_idx)"
    elif [[ -n "$hin_idx" ]]; then
        chosen_idx="$hin_idx"
        chosen_lang="Hindi"
        log_info "  ~ $folder: Hindi audio (stream $hin_idx)"
    elif [[ -n "$first_idx" ]]; then
        chosen_idx="$first_idx"
        chosen_lang="Default"
        log_info "  - $folder: Default audio (stream $first_idx)"
    else
        chosen_lang="Auto"
        log_warn "  ! $folder: No audio detected, using auto-select"
        echo ""
        return
    fi
    
    echo "-map 0:v:0 -map 0:$chosen_idx"
}

log_info "Probing audio tracks (Bengali → Hindi → Default)..."
for i in "${!DISPLAY_NAMES[@]}"; do
    url="${URLS[$i]}"
    folder="${FOLDER_NAMES[$i]}"
    
    map_arg=$(probe_audio_track "$url" "$folder")
    MAP_ARGS+=("$map_arg")
    
    if [[ -n "$map_arg" ]]; then
        if [[ "$map_arg" =~ Bengali ]]; then
            CHOSEN_LANGS+=("Bengali")
        elif [[ "$map_arg" =~ Hindi ]]; then
            CHOSEN_LANGS+=("Hindi")
        else
            CHOSEN_LANGS+=("Default")
        fi
    else
        CHOSEN_LANGS+=("Auto")
    fi
done

# ========================================
# FFmpeg starter (optimized for low latency)
# ========================================
start_ffmpeg() {
    local idx=$1
    local folder="${FOLDER_NAMES[$idx]}"
    local url="${URLS[$idx]}"
    local ch_dir="${HLS_ROOT}/${folder}"
    
    mkdir -p "$ch_dir"
    rm -f "${ch_dir}"/segment*.ts "${ch_dir}"/*.m3u8
    
    local map_opts="${MAP_ARGS[$idx]:-}"
    
    # Optimized FFmpeg command for minimal buffering
    local ffmpeg_cmd=(
        ffmpeg -hide_banner -loglevel error -y
        # Input options
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 20
        -timeout 10000000
        -fflags +genpts+discardcorrupt+nobuffer
        -flags low_delay
        -analyzeduration 2000000 -probesize 2000000
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        -i "$url"
    )
    
    # Add audio mapping if available
    if [[ -n "$map_opts" ]]; then
        ffmpeg_cmd+=($map_opts)
    fi
    
    # Output options (optimized)
    ffmpeg_cmd+=(
        -c:v copy -c:a copy
        -copyts -start_at_zero
        -avoid_negative_ts make_zero
        -max_muxing_queue_size 1024
        # HLS options for low latency
        -f hls
        -hls_time 2
        -hls_list_size 4
        -hls_flags delete_segments+append_list+omit_endlist+independent_segments
        -hls_segment_type mpegts
        -hls_segment_filename "${ch_dir}/segment_%03d.ts"
        -method PUT
        "${ch_dir}/${folder}.m3u8"
    )
    
    # Start FFmpeg in background
    nohup "${ffmpeg_cmd[@]}" \
        >> "${LOG_DIR}/ffmpeg_${folder}.log" 2>&1 &
    
    echo $! > "${ch_dir}/.ffmpeg.pid"
}

# ========================================
# Launch all channels
# ========================================
log_info "Starting FFmpeg for ${#DISPLAY_NAMES[@]} channels..."
for i in "${!DISPLAY_NAMES[@]}"; do
    start_ffmpeg "$i"
    sleep 0.5
done

# Wait for initial segments
log_info "Waiting for initial segments..."
sleep 10

# Validate channels
dead_channels=()
for i in "${!DISPLAY_NAMES[@]}"; do
    folder="${FOLDER_NAMES[$i]}"
    if ! compgen -G "${HLS_ROOT}/${folder}/segment*.ts" > /dev/null; then
        dead_channels+=("${DISPLAY_NAMES[$i]} ($folder)")
    fi
done

if (( ${#dead_channels[@]} > 0 )); then
    log_warn "Channels without segments (${#dead_channels[@]}):"
    printf '%s\n' "${dead_channels[@]}" | head -5
    [[ ${#dead_channels[@]} -gt 5 ]] && log_warn "... and $((${#dead_channels[@]} - 5)) more"
fi

# ========================================
# Generate master playlist
# ========================================
log_info "Generating master playlist..."
{
    echo "#EXTM3U"
    echo "#PLAYLIST:Kobir Shah Multi-Channel Stream"
    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        echo "${EXTINF_LINES[$i]}"
        echo "http://localhost:8080/${folder}/${folder}.m3u8"
    done
} > "$MASTER_PLAYLIST"

# ========================================
# Start Nginx
# ========================================
log_info "Starting Nginx..."

if ! nginx -t -c "$NGINX_CONF" -p /root/ 2>>"${LOG_DIR}/nginx.log"; then
    log_error "Nginx config validation failed!"
    tail -20 "${LOG_DIR}/nginx.log"
    exit 1
fi

nginx -c "$NGINX_CONF" -p /root/ >> "${LOG_DIR}/nginx.log" 2>&1

# Wait for Nginx to start
for i in {1..15}; do
    if ss -tlnp 2>/dev/null | grep -q ':8080'; then
        log_info "Nginx is running on port 8080"
        break
    fi
    sleep 1
    if [[ $i -eq 15 ]]; then
        log_error "Nginx failed to bind to port 8080"
        tail -20 "${LOG_DIR}/nginx_error.log"
        exit 1
    fi
done

# ========================================
# Generate public restream playlist
# ========================================
if [[ -n "$PUBLIC_DOMAIN" ]]; then
    PUBLIC_URL="${PUBLIC_DOMAIN%/}"
else
    PUBLIC_URL="http://localhost:8080"
fi

log_info "Generating restream playlist..."
{
    echo "#EXTM3U"
    echo "#PLAYLIST:Kobir Shah Restream"
    echo "#GENERATED:$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#SOURCE:${PLAYLIST_FILE}"
    echo ""
    
    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        echo "${EXTINF_LINES[$i]}"
        echo "${PUBLIC_URL}/${folder}/${folder}.m3u8"
    done
    
    echo ""
    echo "# Total channels: ${#DISPLAY_NAMES[@]}"
} > "$OUTPUT_PLAYLIST"

log_info "Restream playlist: ${OUTPUT_PLAYLIST}"

# ========================================
# Terminal colors
# ========================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' BOLD='' DIM='' NC=''
fi

# ========================================
# Status monitor loop
# ========================================
log_info "Entering monitoring mode..."
echo ""

while true; do
    clear
    
    # Header
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║  ██╗  ██╗██████╗ ███████╗    ██████╗ ███████╗██╗      █████╗ ║
║  ██║  ██║██╔══██╗██╔════╝    ██╔══██╗██╔════╝██║     ██╔══██╗║
║  ███████║██████╔╝███████╗    ██████╔╝█████╗  ██║     ███████║║
║  ██╔══██║██╔══██╗╚════██║    ██╔══██╗██╔══╝  ██║     ██╔══██║║
║  ██║  ██║██████╔╝███████║    ██║  ██║███████╗███████╗██║  ██║║
║  ╚═╝  ╚═╝╚═════╝ ╚══════╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝║
╚═══════════════════════════════════════════════════════════════╝
EOF
    
    echo -e "${CYAN}           KOBIR SHAH LIVE MULTI-CHANNEL RELAY${NC}"
    echo -e "${MAGENTA}              Developer: Kobir Shah${NC}"
    echo ""
    echo -e "${BOLD}Public URL:${NC}        ${GREEN}${PUBLIC_URL}${NC}"
    echo -e "${BOLD}Restream Playlist:${NC} ${CYAN}${OUTPUT_PLAYLIST}${NC}"
    echo -e "${BOLD}Total Channels:${NC}    ${WHITE}${#DISPLAY_NAMES[@]}${NC}"
    echo ""
    
    # Table header
    printf "${BOLD}%-25s %-10s %-8s %-10s %-10s${NC}\n" \
        "CHANNEL" "STATUS" "SEGS" "UPDATED" "AUDIO"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Channel status
    active_count=0
    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        name="${DISPLAY_NAMES[$i]}"
        ch_dir="${HLS_ROOT}/${folder}"
        playlist="${ch_dir}/${folder}.m3u8"
        audio="${CHOSEN_LANGS[$i]:-Auto}"
        
        # Check if process is running
        if [[ -f "${ch_dir}/.ffmpeg.pid" ]] && kill -0 $(cat "${ch_dir}/.ffmpeg.pid") 2>/dev/null; then
            status="${GREEN}●  UP${NC}"
            
            seg_count=$(compgen -G "${ch_dir}/segment*.ts" | wc -l)
            
            if [[ -f "$playlist" ]]; then
                age=$(($(date +%s) - $(stat -c %Y "$playlist" 2>/dev/null || echo 0)))
                updated="${age}s ago"
            else
                updated="starting"
            fi
            
            ((active_count++))
            rm -f "${ch_dir}/.down_since"
        else
            status="${RED}●  DOWN${NC}"
            seg_count="0"
            updated="-"
            
            # Auto-restart logic
            if [[ ! -f "${ch_dir}/.down_since" ]]; then
                date +%s > "${ch_dir}/.down_since"
            fi
            
            down_time=$(($(date +%s) - $(cat "${ch_dir}/.down_since")))
            if (( down_time >= RESTART_THRESHOLD )); then
                status="${YELLOW}● RESTART${NC}"
                rm -f "${ch_dir}/.down_since"
                start_ffmpeg "$i" &
            fi
        fi
        
        # Color code audio language
        case "$audio" in
            Bengali) audio="${GREEN}${audio}${NC}" ;;
            Hindi)   audio="${BLUE}${audio}${NC}" ;;
            *)       audio="${YELLOW}${audio}${NC}" ;;
        esac
        
        # Truncate long names
        short_name=$(printf "%.23s" "$name")
        [[ ${#name} -gt 23 ]] && short_name="${short_name}.."
        
        printf "%-33s %b  %-8s %-10s %b\n" \
            "$short_name" "$status" "$seg_count" "$updated" "$audio"
    done
    
    echo ""
    echo -e "${BOLD}Status:${NC} ${GREEN}${active_count}${NC} active / ${RED}$((${#DISPLAY_NAMES[@]} - active_count))${NC} down"
    echo ""
    
    # Legend
    echo -e "${GREEN}● Bengali${NC}  ${BLUE}● Hindi${NC}  ${YELLOW}● Default/Auto${NC}"
    echo ""
    
    # Endpoints
    echo -e "${DIM}Endpoints:${NC}"
    echo -e "  ${CYAN}http://localhost:8080/master.m3u8${NC}"
    echo -e "  ${CYAN}http://localhost:8080/restream_playlist.m3u8${NC}"
    echo -e "  ${CYAN}http://localhost:8080/health${NC}"
    echo ""
    
    echo -e "${DIM}Press Ctrl+C to stop monitoring (services continue)${NC}"
    
    sleep 5
done
