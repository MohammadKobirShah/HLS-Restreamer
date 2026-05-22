#!/bin/bash
#
# Multi-channel HLS restreamer (Docker Edition) – with M3U URL import
# Developer: Kobir Shah
# All files stay under /root
#

set -euo pipefail

# ---------- Configuration ----------
PLAYLIST_FILE="/root/playlist.m3u"
M3U_URL="${M3U_URL:-}"                      # optional remote playlist URL
HLS_ROOT="/root/hls"
NGINX_CONF="/root/nginx.conf"
LOG_DIR="/root/logs"
MASTER_PLAYLIST="${HLS_ROOT}/master.m3u8"
OUTPUT_PLAYLIST="/root/restream_playlist.m3u8"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
RESTART_THRESHOLD=15

mkdir -p "$HLS_ROOT" "$LOG_DIR"

# ---------- Fetch remote playlist (if URL given) ----------
if [[ -n "$M3U_URL" ]]; then
    echo "Downloading playlist from $M3U_URL ..."
    if curl -fsSL --connect-timeout 10 --max-time 30 "$M3U_URL" -o "$PLAYLIST_FILE"; then
        echo "Playlist downloaded successfully."
    else
        echo "ERROR: Failed to download playlist from $M3U_URL" >&2
        exit 1
    fi
fi

# ---------- Pre-flight checks ----------
if [[ ! -f "$PLAYLIST_FILE" ]]; then
    echo "ERROR: Playlist not found: $PLAYLIST_FILE" >&2
    echo "Either mount a local file or set M3U_URL environment variable." >&2
    exit 1
fi
if [[ ! -f "$NGINX_CONF" ]]; then
    echo "ERROR: Nginx config not found: $NGINX_CONF" >&2
    exit 1
fi

# ---------- Cleanup ----------
pkill -f "ffmpeg.*${HLS_ROOT}" 2>/dev/null || true
pkill -x nginx                  2>/dev/null || true
sleep 2

chmod 755 /root

# ---------- Parse M3U playlist ----------
declare -a DISPLAY_NAMES=()
declare -a URLS=()
declare -a FOLDER_NAMES=()
declare -a EXTINF_LINES=()

echo "Parsing $PLAYLIST_FILE..."
while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r')
    if [[ "$line" =~ ^#EXTINF: ]]; then
        extinf="$line"
        display_name=$(echo "$line" | sed -n 's/.*,\(.*\)$/\1/p')
        read -r url
        url=$(echo "$url" | tr -d '\r')
        foldername=$(echo "$display_name" | tr -d ' ' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        DISPLAY_NAMES+=("$display_name")
        URLS+=("$url")
        FOLDER_NAMES+=("$foldername")
        EXTINF_LINES+=("$extinf")
    fi
done < "$PLAYLIST_FILE"

if [ ${#DISPLAY_NAMES[@]} -eq 0 ]; then
    echo "No channels found in $PLAYLIST_FILE." >&2
    exit 1
fi

# Deduplicate / fix empty folder names
declare -A FOLDER_SEEN=()
for i in "${!DISPLAY_NAMES[@]}"; do
    folder="${FOLDER_NAMES[$i]}"
    [[ -z "$folder" ]] && folder="channel_${i}"
    while [[ -n "${FOLDER_SEEN[$folder]:-}" ]]; do
        folder="${folder}_$((++FOLDER_SEEN[$folder]))"
    done
    FOLDER_SEEN[$folder]=1
    FOLDER_NAMES[$i]="$folder"
done

# ---------- Audio Language Probing ----------
declare -a MAP_ARGS=()
declare -a CHOSEN_LANGS=()

probe_audio_track() {
    local url="$1"
    local folder="$2"
    local audio_info
    audio_info=$(timeout 20 ffprobe -v error \
        -select_streams a \
        -show_entries stream=index:stream_tags=language \
        -of csv=p=0 \
        -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
        -probesize 5000000 -analyzeduration 5000000 \
        "$url" 2>"${LOG_DIR}/ffprobe_${folder}.log")

    local beng_idx=""
    local hin_idx=""
    local first_idx=""
    local first_lang="unknown"

    if [[ -n "$audio_info" ]]; then
        while IFS=, read -r idx lang; do
            idx=$(echo "$idx" | xargs)
            lang=$(echo "$lang" | xargs | tr '[:upper:]' '[:lower:]')
            if [[ -z "$first_idx" && -n "$idx" ]]; then
                first_idx="$idx"
                first_lang="$lang"
            fi
            if [[ "$lang" == "ben" || "$lang" == "beng" || "$lang" == "bengali" ]]; then
                beng_idx="$idx"
            fi
            if [[ "$lang" == "hin" || "$lang" == "hindi" ]]; then
                hin_idx="$idx"
            fi
        done <<< "$audio_info"
    fi

    if [[ -z "$first_idx" ]]; then
        echo "  [!] $folder: No audio tracks detected -- using auto-select" >&2
        CHOSEN_LANGS+=("auto")
        return
    fi

    local chosen_idx="$first_idx"
    local chosen_lang="${first_lang^}"

    if [[ -n "$beng_idx" ]]; then
        chosen_idx="$beng_idx"
        chosen_lang="Bengali"
        echo "  [OK] $folder: Bengali audio found (stream $beng_idx)" >&2
    elif [[ -n "$hin_idx" ]]; then
        chosen_idx="$hin_idx"
        chosen_lang="Hindi"
        echo "  [~~] $folder: Bengali not found, using Hindi (stream $hin_idx)" >&2
    else
        echo "  [--] $folder: No Bengali/Hindi -- using default ($chosen_lang, stream $first_idx)" >&2
    fi

    CHOSEN_LANGS+=("$chosen_lang")
    echo "-map 0:v:0 -map 0:$chosen_idx"
}

echo ""
echo "Probing audio tracks (Priority: Bengali -> Hindi -> Default)..."
for i in "${!DISPLAY_NAMES[@]}"; do
    url="${URLS[$i]}"
    folder="${FOLDER_NAMES[$i]}"
    map_arg=$(probe_audio_track "$url" "$folder")
    MAP_ARGS+=("$map_arg")
done
echo ""

# ---------- Helper: launch FFmpeg ----------
start_ffmpeg() {
    local idx=$1
    local folder="${FOLDER_NAMES[$idx]}"
    local url="${URLS[$idx]}"
    local ch_dir="${HLS_ROOT}/${folder}"
    mkdir -p "$ch_dir"
    rm -f "${ch_dir}"/segment_*.ts "${ch_dir}"/*.m3u8

    local map_opts="${MAP_ARGS[$idx]:-}"

    if [[ -n "$map_opts" ]]; then
        nohup ffmpeg -y \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 \
            -fflags +genpts+discardcorrupt \
            -avoid_negative_ts make_zero \
            -err_detect ignore_err \
            -probesize 5000000 -analyzeduration 5000000 \
            -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            -i "$url" \
            $map_opts \
            -c copy \
            -f hls \
            -hls_time 4 \
            -hls_list_size 6 \
            -hls_flags delete_segments+append_list+independent_segments \
            -hls_segment_filename "${ch_dir}/segment_%03d.ts" \
            "${ch_dir}/${folder}.m3u8" \
            >> "${LOG_DIR}/ffmpeg_${folder}.log" 2>&1 &
    else
        nohup ffmpeg -y \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 30 \
            -fflags +genpts+discardcorrupt \
            -avoid_negative_ts make_zero \
            -err_detect ignore_err \
            -probesize 5000000 -analyzeduration 5000000 \
            -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            -i "$url" \
            -c copy \
            -f hls \
            -hls_time 4 \
            -hls_list_size 6 \
            -hls_flags delete_segments+append_list+independent_segments \
            -hls_segment_filename "${ch_dir}/segment_%03d.ts" \
            "${ch_dir}/${folder}.m3u8" \
            >> "${LOG_DIR}/ffmpeg_${folder}.log" 2>&1 &
    fi
}

# ---------- Launch all FFmpegs ----------
echo "Starting FFmpeg for ${#DISPLAY_NAMES[@]} channels..."
for i in "${!DISPLAY_NAMES[@]}"; do
    start_ffmpeg "$i"
done
sleep 8

# Validate initial segments
dead=()
for i in "${!DISPLAY_NAMES[@]}"; do
    folder="${FOLDER_NAMES[$i]}"
    if ! ls "${HLS_ROOT}/${folder}"/segment_*.ts &>/dev/null; then
        dead+=("${DISPLAY_NAMES[$i]}")
    fi
done
if (( ${#dead[@]} )); then
    echo ""
    echo "WARNING: No segments yet for: ${dead[*]}"
    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        if ! ls "${HLS_ROOT}/${folder}"/segment_*.ts &>/dev/null; then
            echo "--- ${folder} (last 3 lines) ---"
            tail -3 "${LOG_DIR}/ffmpeg_${folder}.log" 2>/dev/null || echo "(no log)"
        fi
    done
    echo ""
fi

# ---------- Generate master playlist ----------
echo "#EXTM3U" > "$MASTER_PLAYLIST"
echo "#PLAYLIST: Kobir Shah Multi-Channel Stream" >> "$MASTER_PLAYLIST"
for i in "${!DISPLAY_NAMES[@]}"; do
    folder="${FOLDER_NAMES[$i]}"
    echo "${EXTINF_LINES[$i]}" >> "$MASTER_PLAYLIST"
    echo "http://localhost:8080/${folder}/${folder}.m3u8" >> "$MASTER_PLAYLIST"
done

# ---------- Start Nginx ----------
cp -f "$NGINX_CONF" /root/nginx.conf.active
if ! nginx -t -c /root/nginx.conf.active -p /root/ 2>>"${LOG_DIR}/nginx.log"; then
    echo "ERROR: Nginx config validation failed!" >&2
    cat "${LOG_DIR}/nginx.log" >&2
    exit 1
fi

nohup nginx -c /root/nginx.conf.active -p /root/ >> "${LOG_DIR}/nginx.log" 2>&1 &
sleep 2

if ! pgrep -x nginx > /dev/null; then
    echo "ERROR: Nginx failed to start!" >&2
    tail -20 "${LOG_DIR}/nginx.log" >&2
    tail -20 "${LOG_DIR}/nginx_error.log" >&2
    exit 1
fi

RETRIES=0
while ! ss -tlnp 2>/dev/null | grep -q ':8080' && ! netstat -tlnp 2>/dev/null | grep -q ':8080'; do
    RETRIES=$((RETRIES + 1))
    if (( RETRIES > 10 )); then
        echo "ERROR: Nginx is not listening on port 8080!" >&2
        tail -20 "${LOG_DIR}/nginx_error.log" >&2
        exit 1
    fi
    sleep 1
done
echo "Nginx is running on port 8080"

# ---------- Public URL ----------
if [[ -n "$PUBLIC_DOMAIN" ]]; then
    PUBLIC_URL="${PUBLIC_DOMAIN%/}"
else
    PUBLIC_URL="http://localhost:8080"
fi

# ---------- Generate output restream playlist ----------
generate_output_playlist() {
    local base_url="$1"
    cat > "$OUTPUT_PLAYLIST" <<'HEADER'
#EXTM3U
HEADER
    echo "#PLAYLIST: Kobir Shah Restream" >> "$OUTPUT_PLAYLIST"
    echo "#GENERATED: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$OUTPUT_PLAYLIST"
    echo "#SOURCE: ${PLAYLIST_FILE}" >> "$OUTPUT_PLAYLIST"
    echo "" >> "$OUTPUT_PLAYLIST"

    for i in "${!DISPLAY_NAMES[@]}"; do
        local folder="${FOLDER_NAMES[$i]}"
        local extinf="${EXTINF_LINES[$i]}"
        local restream_url="${base_url}/${folder}/${folder}.m3u8"
        echo "${extinf}" >> "$OUTPUT_PLAYLIST"
        echo "${restream_url}" >> "$OUTPUT_PLAYLIST"
    done
    echo "" >> "$OUTPUT_PLAYLIST"
    echo "# ${#DISPLAY_NAMES[@]} channels" >> "$OUTPUT_PLAYLIST"
}

generate_output_playlist "$PUBLIC_URL"
echo "Restream playlist generated: ${OUTPUT_PLAYLIST}"

# ---------- Colours ----------
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
WHITE=$'\033[1;37m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

ASCII_ART=$'\n      :::::::::  :::    ::: ::::::::: ::::::::: \n     :::    ::: :::    ::: :       : :        \n    :+:    :+:   :+:       :+:    :+: :+:        \n   +#++:++#+  +#++:++#++ +#++:++#  +#++:++#   \n  +#+    +#+ +#+    +#+ +#+    +#+ +#+         \n #+#    #+# #+#    #+# #+#    #+# #+#          \n###    ###  ########  #########  ##########    '

# ---------- TUI Monitor ----------
while true; do
    clear
    echo -e "${MAGENTA}${ASCII_ART}${NC}"
    echo -e "${YELLOW}${BOLD}           KOBIR SHAH LIVE MULTI-CHANNEL RELAY${NC}"
    echo -e "${CYAN}                   Developer: Kobir Shah${NC}"
    echo -e "${WHITE}??????????????????????????????????????????????????????????????????????????????${NC}"
    echo -e "${BOLD}Public URL:${NC}       ${GREEN}${PUBLIC_URL}${NC}"
    echo -e "${BOLD}Restream Playlist:${NC} ${CYAN}${OUTPUT_PLAYLIST}${NC}"
    echo ""
    printf "${BOLD}%-20s %-9s %-12s %-12s %-10s %s${NC}\n" "CHANNEL" "STATUS" "SEGMENTS" "ALIVE" "AUDIO" "RESTREAM URL"
    echo "????????????????????????????????????????????????????????????????????????????????????"

    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        name="${DISPLAY_NAMES[$i]}"
        ch_dir="${HLS_ROOT}/${folder}"
        playlist="${ch_dir}/${folder}.m3u8"
        restream_url="${PUBLIC_URL}/${folder}/${folder}.m3u8"
        audio_lang="${CHOSEN_LANGS[$i]:-auto}"

        if pgrep -f "ffmpeg.*${folder}" > /dev/null; then
            status="${GREEN}UP${NC}"
            seg_count=$(find "$ch_dir" -name 'segment_*.ts' 2>/dev/null | wc -l)
            if [ -f "$playlist" ]; then
                alive_sec=$(( $(date +%s) - $(stat -c %Y "$playlist") ))
                alive="${alive_sec}s"
            else
                alive="starting"
            fi
            rm -f "${ch_dir}/.down_since"
        else
            status="${RED}DOWN${NC}"
            seg_count="0"
            alive="?"
            restream_url="?"

            if [[ ! -f "${ch_dir}/.down_since" ]]; then
                date +%s > "${ch_dir}/.down_since"
            fi
            down_since=$(cat "${ch_dir}/.down_since")
            now=$(date +%s)
            if (( now - down_since > RESTART_THRESHOLD )); then
                rm -f "${ch_dir}/.down_since"
                start_ffmpeg "$i"
                status="${YELLOW}RESTART${NC}"
                alive="reconnecting"
                restream_url="..."
            fi
        fi

        audio_display=""
        if [[ "$audio_lang" == "Bengali" ]]; then
            audio_display="${GREEN}${audio_lang}${NC}"
        elif [[ "$audio_lang" == "Hindi" ]]; then
            audio_display="${BLUE}${audio_lang}${NC}"
        else
            audio_display="${YELLOW}${audio_lang}${NC}"
        fi

        printf "${BOLD}%-20s${NC} %b %-12s %-12s %b %s\n" "$name" "$status" "$seg_count" "$alive" "$audio_display" "$restream_url"
    done

    down_folders=()
    for i in "${!DISPLAY_NAMES[@]}"; do
        folder="${FOLDER_NAMES[$i]}"
        if ! pgrep -f "ffmpeg.*${folder}" > /dev/null; then
            down_folders+=("$folder")
        fi
    done

    if (( ${#down_folders[@]} > 0 )); then
        echo ""
        echo -e "${RED}${BOLD}[!] DOWN CHANNELS -- Last errors:${NC}"
        echo -e "${DIM}?????????????????????????????????????????????????????????${NC}"
        for df in "${down_folders[@]:0:3}"; do
            echo -e "${DIM}${df}:${NC}"
            tail -2 "${LOG_DIR}/ffmpeg_${df}.log" 2>/dev/null | head -2 | while read -r err_line; do
                echo -e "${DIM}  ${err_line}${NC}"
            done
        done
        if (( ${#down_folders[@]} > 3 )); then
            echo -e "${DIM}  ... and $(( ${#down_folders[@]} - 3 )) more${NC}"
        fi
    fi

    echo ""
    echo -e "${WHITE}??????????????????????????????????????????????????????????????????????????????${NC}"
    if pgrep -x nginx > /dev/null; then
        echo -e "${GREEN}[NGINX]${NC} Running on port 8080"
    else
        echo -e "${RED}[NGINX]${NC} NOT RUNNING!"
    fi
    echo -e "${GREEN}? Bengali${NC}  ${BLUE}? Hindi${NC}  ${YELLOW}? Default/Other${NC}"
    echo -e "${YELLOW}Master Playlist:${NC}    file://${MASTER_PLAYLIST}"
    echo -e "${YELLOW}Restream Output:${NC}   file://${OUTPUT_PLAYLIST}"
    echo -e "${YELLOW}Local test:${NC}        curl http://localhost:8080/<folder>/<folder>.m3u8"
    echo ""
    echo -e "${MAGENTA}Press Ctrl+C to stop the TUI (services keep running)${NC}"
    sleep 3
done
