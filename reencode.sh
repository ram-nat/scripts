#!/usr/bin/env zsh

# plex_normalize.sh: Re-encode multiple MKVs for Plex with HDR preservation and normalized AC3 audio.

function usage() {
    echo "Usage:"
    echo "  $0 [--two-pass] input1.mkv input2.mkv ... OR $0 [--two-pass] directory/"
    echo ""
    echo "Options:"
    echo "  --two-pass    Use two-pass audio normalization (default: single-pass)"
    exit 1
}

# Check dependencies
if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
    echo "Error: ffmpeg/ffprobe not found!" >&2
    exit 1
fi

# Configuration
MAX_JOBS=2  # NVIDIA consumer GPUs support 2 simultaneous NVENC sessions
AUDIO_BITRATE=640k
PRESET="p6"
USE_TWO_PASS=false
INPUT_FILES=()

# Semaphore setup using mktemp
SEMAPHORE_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" reencode_semaphore.XXXXXXXXXX) || exit 1
SEMAPHORE_FIFO="${SEMAPHORE_DIR}/control.fifo"

# Initialize semaphore
init_semaphore() {
    mkfifo -m 600 "$SEMAPHORE_FIFO" || {
        echo "Failed to create FIFO" >&2
        cleanup 1
    }
    exec 3<>"$SEMAPHORE_FIFO"
    
    # Fill semaphore with tokens
    local i
    for ((i=0; i<MAX_JOBS; i++)); do
        echo "token" >&3
    done
}

# Acquire semaphore token
acquire_token() {
    local token
    read token <&3
}

# Release semaphore token
release_token() {
    echo "token" >&3
}

# Cleanup function
cleanup() {
    exec 3>&-
    rm -rf "$SEMAPHORE_DIR"
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
    exit ${1:-0}
}

# Set up cleanup trap
trap 'cleanup 1' INT TERM EXIT

# Parse arguments (same as original)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --two-pass)
            USE_TWO_PASS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            INPUT_FILES+=("$1")
            shift
            ;;
    esac
done

# Collect input files (same as original)
if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
    echo "Error: No input files/directories specified!" >&2
    usage
fi

# Expand directories to MKV files (same as original)
expanded_files=()
for input in "${INPUT_FILES[@]}"; do
    if [[ -d "$input" ]]; then
        while IFS= read -r -d $'\0' file; do
            expanded_files+=("$file")
        done < <(find "$input" -name '*.mkv' -print0 2>/dev/null)
    elif [[ -f "$input" ]]; then
        expanded_files+=("$input")
    else
        echo "Error: '$input' not found!" >&2
        exit 1
    fi
done

if [[ ${#expanded_files[@]} -eq 0 ]]; then
    echo "Error: No MKV files found!" >&2
    exit 1
fi

# Function to process a single file with semaphore control
process_file() {
    local input_file="$1"
    local output_file="${input_file:r}_normalized.mkv"
    local json_stats
    
    # Acquire semaphore token
    acquire_token
    
    # Detect video properties for color metadata handling
    local hdr_params=()
    local probed_info
    probed_info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer,stream=pix_fmt,stream=color_primaries,stream=colorspace \
        -of default=nw=1:nk=1 "${input_file}")

    # Read ffprobe output line by line into an array
    # Order: color_transfer, pix_fmt, color_primaries, colorspace
    local ffprobe_output_array=()
    while IFS= read -r line; do
        ffprobe_output_array+=("$line")
    done <<< "$probed_info"

    local color_trc="${ffprobe_output_array[0]}"
    local input_pix_fmt="${ffprobe_output_array[1]}"
    local color_primaries="${ffprobe_output_array[2]}" # May be "N/A" or "unknown"
    local colorspace="${ffprobe_output_array[3]}"    # May be "N/A" or "unknown"

    if [[ "$color_trc" == "smpte2084" || "$color_trc" == "arib-std-b67" ]]; then
        # Handle common HDR types (HDR10/PQ, HLG)
        hdr_params=(
            -color_primaries bt2020 # Standard for these HDR formats
            -color_trc "${color_trc}"
            -colorspace bt2020nc   # Standard for these HDR formats
            -pix_fmt p010le        # Common 10-bit format for HDR with NVENC
        )
    elif [[ "$input_pix_fmt" == *10le || "$input_pix_fmt" == *10be || "$input_pix_fmt" == "p010le" ]]; then
        # Handle 10-bit SDR: preserve original 10-bit pixel format and explicitly pass SDR color metadata.
        hdr_params=(
            -pix_fmt "$input_pix_fmt" # Preserve 10-bit depth
        )
        # Pass through original SDR color metadata if valid
        if [[ -n "$color_primaries" && "$color_primaries" != "unknown" && "$color_primaries" != "N/A" ]]; then
            hdr_params+=(-color_primaries "$color_primaries")
        fi
        # color_trc is known not to be smpte2084 or arib-std-b67 here.
        if [[ -n "$color_trc" && "$color_trc" != "unknown" && "$color_trc" != "N/A" ]]; then
            hdr_params+=(-color_trc "$color_trc")
        fi
        if [[ -n "$colorspace" && "$colorspace" != "unknown" && "$colorspace" != "N/A" ]]; then
            hdr_params+=(-colorspace "$colorspace")
        fi
    fi

    # Audio normalization (same as original)
    local audio_filter=()
    if [[ "$USE_TWO_PASS" == "true" ]]; then
        json_stats=$(mktemp)
        ffmpeg -nostdin -hide_banner -y -i "${input_file}" -map 0:a:0 \
            -af loudnorm=print_format=json -f null /dev/null 2> "${json_stats}"
        
        local measured_i=$(grep -oP '"input_i"\s*:\s*"\K[^"]+' "${json_stats}")
        local measured_tp=$(grep -oP '"input_tp"\s*:\s*"\K[^"]+' "${json_stats}")
        local measured_lra=$(grep -oP '"input_lra"\s*:\s*"\K[^"]+' "${json_stats}")
        local measured_thresh=$(grep -oP '"input_thresh"\s*:\s*"\K[^"]+' "${json_stats}")
        local offset=$(grep -oP '"target_offset"\s*:\s*"\K[^"]+' "${json_stats}")

        audio_filter=(
            -filter:a:1 "loudnorm=I=-23:LRA=7:TP=-2.0:
                measured_I=${measured_i}:measured_tp=${measured_tp}:
                measured_lra=${measured_lra}:measured_thresh=${measured_thresh}:
                offset=${offset}:linear=true"
        )
        rm "${json_stats}"
    else
        audio_filter=(
            -filter:a:1 "loudnorm=I=-23:LRA=7:TP=-2.0"
        )
    fi

    # Encoding command - stderr preserved for stats visibility
    ffmpeg -nostdin -loglevel error -stats -hide_banner -y \
        -c:v hevc_cuvid -i "${input_file}" \
        < /dev/null \
        -map 0:v:0 -map 0:a:0 -map 0:a:0 -map '0:s?' \
        -c:v hevc_nvenc \
        -preset "${PRESET}" \
        -rc:v vbr_hq \
        -b:v 15M -maxrate 25M -bufsize 30M \
        "${hdr_params[@]}" \
        -c:a:0 copy \
        -c:a:1 ac3 -b:a:1 "${AUDIO_BITRATE}" \
        "${audio_filter[@]}" \
        -c:s copy \
        -metadata:s:a:1 title="Normalized Audio" \
        "${output_file}"
    
    # Release semaphore token when job completes
    release_token
    echo "Completed: ${input_file}"
}

# Initialize semaphore
init_semaphore

# Process files in parallel
for input_file in "${expanded_files[@]}"; do
    echo "Starting: ${input_file}"
    (process_file "$input_file") &
done

# Wait for all jobs to complete
wait
echo "All conversions completed!"

# Clean up (trap will handle this)
exec 3>&-
trap - INT TERM EXIT
