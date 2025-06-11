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
MAX_JOBS=4  # NVIDIA consumer GPUs support 2 simultaneous NVENC sessions
AUDIO_BITRATE=640k
PRESET="p6"
USE_TWO_PASS=false
INPUT_FILES=()

# Semaphore setup using mktemp
SEMAPHORE_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" reencode_semaphore.XXXXXXXXXX) || exit 1
SEMAPHORE_FIFO="${SEMAPHORE_DIR}/control.fifo"
SHUTTING_DOWN_FLAG_FILE="${SEMAPHORE_DIR}/shutting_down"

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
    # -r: do not allow backslashes to escape any characters
    if ! read -r token <&3; then
        return 1 # Failure (e.g., FIFO closed during shutdown)
    fi
    return 0 # Success
}

# Release semaphore token
release_token() {
    echo "token" >&3
}

# Cleanup function
cleanup() {
    local exit_code=${1:-0} # Default to 0 if no argument from trap

    # 1. Signal intent to shut down by creating a flag file.
    # Done early so sub-processes can see it.
    if [[ -d "$SEMAPHORE_DIR" ]]; then # Check if SEMAPHORE_DIR was successfully created
        touch "${SHUTTING_DOWN_FLAG_FILE}" 2>/dev/null
    fi

    # 2. Close the master file descriptor for the FIFO in the parent shell.
    # This will cause 'read <&3' in children to receive EOF if they are waiting.
    exec 3>&-

    # 3. If called due to a signal (argument $1 is non-empty, e.g., 1 from trap), terminate child processes.
    if [[ -n "$1" ]]; then # Indicates called from INT/TERM trap
        printf "\n⚠️ Signal received. Terminating running jobs... " >&2
        jobs -p | xargs -r kill 2>/dev/null # Send TERM signal to background job PIDs
        wait 2>/dev/null # Wait for them to terminate
        printf "Done.\n" >&2
    fi

    # 4. Remove the semaphore directory (which includes the FIFO and the flag file)
    rm -rf "$SEMAPHORE_DIR"
    exit "$exit_code"
}
# Set up cleanup trap - exit with exit code 0 on normal exit, 1 on error
trap 'cleanup' EXIT
trap 'cleanup 1' INT TERM

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

echo "Will process all these files: ${expanded_files[@]}"

# Function to process a single file with semaphore control
process_file() {
    local input_file="$1"
    local output_file="${input_file:r}_normalized.mkv"
    local json_stats

    # Check shutdown flag before attempting to acquire token
    if [[ -f "$SHUTTING_DOWN_FLAG_FILE" ]]; then
        printf "Skipping %s (queued): Shutdown signaled.\n" "$input_file" >&2
        return 1
    fi

    if ! acquire_token; then
        # acquire_token failed, likely due to FIFO closure during shutdown.
        printf "Skipping %s: Token acquisition failed (likely shutdown).\n" "$input_file" >&2
        return 1
    fi

    # Double-check shutdown flag after acquiring token, as signal could arrive while waiting
    if [[ -f "$SHUTTING_DOWN_FLAG_FILE" ]]; then
        printf "Skipping %s: Shutdown signaled after token acquisition.\n" "$input_file" >&2
        release_token # Release the acquired token as we are not proceeding
        return 1
    fi

    # Print processing status, \r to allow ffmpeg stats to overwrite
    printf "⚙️ Processing: %s\r" "$input_file"


    # Detect video properties for color metadata handling
    local hdr_params=()
    local probed_info
    probed_info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer,stream=pix_fmt,stream=color_primaries,stream=colorspace \
        -of default=nw=1:nk=1 "${input_file}" 2>/dev/null)

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
    ffmpeg -nostdin -loglevel error -hide_banner -y \
        -hwaccel cuvid -c:v hevc_cuvid -i "${input_file}" \
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
    local ffmpeg_exit_code=$?

    # Release semaphore token when job completes
    release_token

    # Clear the "Processing..." line before printing final status
    printf "\r\033[K"
    if [[ $ffmpeg_exit_code -eq 0 ]]; then
        printf "✅ Completed: %s\n" "$input_file"
    elif [[ -f "$SHUTTING_DOWN_FLAG_FILE" ]]; then # Check if failure was due to shutdown
        printf "⏹️ Interrupted: %s\n" "$input_file" >&2
    else
        printf "❌ Failed: %s (ffmpeg exit code: %s)\n" "$input_file" "$ffmpeg_exit_code" >&2
    fi
    return $ffmpeg_exit_code
}
# Initialize semaphore
init_semaphore

# Process files in parallel
for input_file in "${expanded_files[@]}"; do
    printf "➕ Queued: %s\n" "$input_file"
    (process_file "$input_file") &
done

# Wait for all jobs to complete
wait
printf "🎉 All conversions completed!\n"
