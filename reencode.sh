#!/usr/bin/env bash

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
MAX_JOBS=4  # Change this for number of parallel encodes
AUDIO_BITRATE=640k
PRESET="p6"
USE_TWO_PASS=false
INPUT_FILES=()
expanded_files=()

# Semaphore setup using mktemp
SEMAPHORE_DIR=$(mktemp -d -p "${TMPDIR:-/tmp}" reencode_semaphore.XXXXXXXXXX) || exit 1
PROGRESS_DIR="${SEMAPHORE_DIR}/progress"
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
    exec 4>&- # Close the status FIFO

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

# Function to determine HDR parameters for ffmpeg.
# Arguments:
#   $1: input_file
#   $2: nameref for the output hdr_params array
# Modifies:
#   The array referenced by $2 with ffmpeg parameters for HDR handling.
determine_hdr_params() {
    local input_file="$1"
    local -n _hdr_params_ref="$2" # Nameref to the caller's array

    _hdr_params_ref=() # Initialize/clear the array

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

    # Use parameter expansion with defaults to avoid errors if ffprobe output is incomplete
    local color_trc="${ffprobe_output_array[0]:-}"
    local input_pix_fmt="${ffprobe_output_array[1]:-}"
    local color_primaries="${ffprobe_output_array[2]:-}" # May be "N/A" or "unknown"
    local colorspace="${ffprobe_output_array[3]:-}"    # May be "N/A" or "unknown"

    if [[ "$color_trc" == "smpte2084" || "$color_trc" == "arib-std-b67" ]]; then
        # Handle common HDR types (HDR10/PQ, HLG)
        _hdr_params_ref=(
            "-color_primaries" "bt2020" # Standard for these HDR formats
            "-color_trc" "${color_trc}"
            "-colorspace" "bt2020nc"   # Standard for these HDR formats
            "-pix_fmt" "p010le"        # Common 10-bit format for HDR with NVENC
        )
    elif [[ "$input_pix_fmt" == *10le || "$input_pix_fmt" == *10be || "$input_pix_fmt" == "p010le" ]]; then
        # Handle 10-bit SDR: preserve original 10-bit pixel format and explicitly pass SDR color metadata.
        _hdr_params_ref=("-pix_fmt" "$input_pix_fmt") # Preserve 10-bit depth
        # Pass through original SDR color metadata if valid
        if [[ -n "$color_primaries" && "$color_primaries" != "unknown" && "$color_primaries" != "N/A" ]]; then
            _hdr_params_ref+=("-color_primaries" "$color_primaries")
        fi
        # color_trc is known not to be smpte2084 or arib-std-b67 here.
        if [[ -n "$color_trc" && "$color_trc" != "unknown" && "$color_trc" != "N/A" ]]; then
            _hdr_params_ref+=("-color_trc" "$color_trc")
        fi
        if [[ -n "$colorspace" && "$colorspace" != "unknown" && "$colorspace" != "N/A" ]]; then
            _hdr_params_ref+=("-colorspace" "$colorspace")
        fi
    fi
}

# Function to determine audio filter parameters for ffmpeg.
# Arguments:
#   $1: input_file
#   $2: USE_TWO_PASS (boolean string "true" or "false")
#   $3: nameref for the output audio_filter array
# Modifies:
#   The array referenced by $3 with ffmpeg audio filter parameters.
determine_audio_filter_params() {
    local input_file="$1"
    local use_two_pass_flag="$2"
    local -n _audio_filter_ref="$3" # Nameref to the caller's array

    _audio_filter_ref=("-map" "0:a" "-c:a" "copy")

    # Find number of audio streams
    local audio_streams_count
    audio_streams_count=$(ffprobe -v error -select_streams a -show_entries stream=index -of json "${input_file}" | jq '.streams | length')
    if (( audio_streams_count < 1 )); then
        return 0
    fi

    _audio_filter_ref=() # Map the first audio stream for normalization
    local normalization_filter=()
    if [[ "$use_two_pass_flag" == "true" ]]; then
        local json_stats_file
        json_stats_file=$(mktemp -p "${SEMAPHORE_DIR:-/tmp}" audio_stats.XXXXXXXXXX)
        ffmpeg -nostdin -hide_banner -y -i "${input_file}" -map 0:a:0 \
            -af loudnorm=print_format=json -f null /dev/null 2> "${json_stats_file}"

        local measured_i=$(grep -oP '"input_i"\s*:\s*"\K[^"]+' "${json_stats_file}")
        local measured_tp=$(grep -oP '"input_tp"\s*:\s*"\K[^"]+' "${json_stats_file}")
        local measured_lra=$(grep -oP '"input_lra"\s*:\s*"\K[^"]+' "${json_stats_file}")
        local measured_thresh=$(grep -oP '"input_thresh"\s*:\s*"\K[^"]+' "${json_stats_file}")
        local offset=$(grep -oP '"target_offset"\s*:\s*"\K[^"]+' "${json_stats_file}")

        normalization_filter=(
            "-filter:a:0" "loudnorm=I=-23:LRA=7:TP=-2.0:measured_I=${measured_i}:measured_tp=${measured_tp}:measured_lra=${measured_lra}:measured_thresh=${measured_thresh}:offset=${offset}:linear=true"
        )
        rm "${json_stats_file}"
    else
        normalization_filter=("-filter:a:0" "loudnorm=I=-23:LRA=7:TP=-2.0")
    fi
    # Add new audio stream for normalization
    _audio_filter_ref=(
        "-map" "0:a:0"    # Map the first audio stream for normalization
        "-map" "0:a"      # Map all audio streams
        "-c:a" "copy"     # Copy all audio streams
        "-c:a:0"          # Copy the first audio stream as AC3 with normalization
        "ac3"
        "-b:a:0"
        "${AUDIO_BITRATE}"
        ${normalization_filter[@]}
        "-metadata:s:a:0" "title=Normalized Audio"
    )
}

monitor_progress() {
    local progress_fifo_name="$1"
    local input_file="$2"
    local time_sec=0

    # Read progress updates from the FIFO
    while IFS= read -r line; do
        case "$line" in
            # Handle ffmpeg progress updates
            *out_time_us=*)
                time_sec=${line#*=}
                time_sec=$((time_sec / 1000000))
                ;;
            *progress=*)
                local status=${line#*=}
                printf "%s %s %s\n" "$time_sec" "$status" "$input_file" >&4
                ;;
        esac
    done < "$progress_fifo_name"
}

# Function to process a single file with semaphore control
process_file() {
    local input_file="$1"
    local output_file="${input_file%.*}_normalized.mkv"
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

    # Determine HDR parameters
    local hdr_params=()
    determine_hdr_params "$input_file" hdr_params

    # Determine audio filter parameters
    local audio_filter=()
    determine_audio_filter_params "$input_file" "$USE_TWO_PASS" audio_filter

    local progress_fifo_name=$(mktemp -u "${PROGRESS_DIR}/progress.XXXXXXXXXX")
    # Create a named pipe for progress updates
    mkfifo -m 600 "$progress_fifo_name" || {
        printf "Error: Failed to create progress FIFO for %s!\n" "$input_file" >&2
        release_token
        return 1
    }

    # Start monitoring progress in the background
    monitor_progress "$progress_fifo_name" "$input_file" &

    # Encoding command - stderr preserved for stats visibility
    ffmpeg -nostdin -loglevel error -hide_banner -y \
        -progress "$progress_fifo_name" \
        -stats_period 5 \
        -hwaccel nvdec -i "${input_file}" \
        -map 0:v:0 -map '0:s?' \
        -c:v hevc_nvenc \
        -preset "${PRESET}" \
        -rc:v vbr_hq \
        -b:v 15M -maxrate 25M -bufsize 30M \
        "${hdr_params[@]}" \
        "${audio_filter[@]}" \
        -c:s copy \
        "${output_file}"
    local ffmpeg_exit_code=$?

    # Release semaphore token when job completes
    release_token

    # if [[ $ffmpeg_exit_code -eq 0 ]]; then
    #     printf "✅ Completed: %s\n" "$input_file"
    # elif [[ -f "$SHUTTING_DOWN_FLAG_FILE" ]]; then # Check if failure was due to shutdown
    #     printf "⏹️ Interrupted: %s\n" "$input_file" >&2
    # else
    #     printf "❌ Failed: %s (ffmpeg exit code: %s)\n" "$input_file" "$ffmpeg_exit_code" >&2
    # fi
    return $ffmpeg_exit_code
}

# Parse script arguments
# Populates global: USE_TWO_PASS, INPUT_FILES
parse_script_arguments() {
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

    if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
        echo "Error: No input files/directories specified!" >&2
        usage
    fi
}

# Collect and expand input files
# Uses global: INPUT_FILES
# Populates global: expanded_files
prepare_file_list() {
    for input in "${INPUT_FILES[@]}"; do
        if [[ -d "$input" ]]; then
            # Use a subshell for find to avoid issues with IFS in the main script if not careful
            local found_in_dir=()
            while IFS= read -r -d $'\0' file; do
                found_in_dir+=("$file")
            done < <(find "$input" -name '*.mkv' -print0 2>/dev/null)
            expanded_files+=("${found_in_dir[@]}")
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
}

calculate_total_duration() {
    local -n _total_duration_ref=$1 # Nameref to the caller's variable
    _total_duration_ref=0
    # Calculate total duration of all files
    for file in "${expanded_files[@]}"; do
        local duration
        duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$file")
        duration=${duration%.*}
        if ((duration)) 2>/dev/null; then
            _total_duration_ref=$(($_total_duration_ref + ${duration})) # Convert to integer seconds
        fi
    done
}

# Process all files in parallel
# Uses global: expanded_files
do_reencoding() {
    local -n _encoding_job_pids_ref=$1 # Nameref to the caller's variable
    for input_file in "${expanded_files[@]}"; do
        (process_file "$input_file") & # Run in subshell to allow parallel execution
        _encoding_job_pids_ref+=($!) # Store the PID of the background job
    done
}

# An enhanced progress bar with color and a spinner
# Arg1: Current value
# Arg2: Total value
print_progress_bar() {
    local current=$1
    local total=$2
    local extra_text=${3:-""} # Optional extra text to display

    # --- CONFIGURATION ---
    local text_width=$((10 + ${#extra_text})) # Width for the text part of the bar
    local max_width=50 # Maximum width of the progress bar
    local terminal_width=$(tput cols 2>/dev/null || echo $max_width) # Get terminal width
    local width=$((terminal_width < max_width ? terminal_width : max_width)) # Limit total bar width (including text)
    width=$((width - $text_width)) # Calculate available width for the progress bar

    # --- STATE ---
    # A static variable to hold the spinner state
    # In bash, we simulate this by using a global-like variable name
    # or by passing state in and out, but this is simpler for an example.
    ((_SPINNER_STATE++))
    local spinner_chars=('|' '/' '-' '\')
    local spinner_char=${spinner_chars[_SPINNER_STATE % 4]}

    # --- CALCULATIONS ---
    local scale=10000 # Calculate up to four decimal places for progress

    # Unicode blocks for fractions of a character cell.
    local blocks=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█")

    local current_scaled=$((current * scale / total))
    local progress_bar_scaled=$((current_scaled * width / scale))
    local remainder=$((current_scaled * width % scale))
    local partial_block_index=$((remainder * 8 / scale)) # 8 because we have 9 blocks (0-8)

    local bar_string="" # Start with the color for the bar
    for ((i = 0; i < progress_bar_scaled; i++)); do
        # Fill the bar with full blocks
        bar_string+="${blocks[8]}" # Full block
    done

    local partial_block=""
    if ((partial_block_index >= 0 && partial_block_index < 8)); then
        # Add the partial block if there is a remainder
        partial_block="${blocks[partial_block_index]}"
    fi

    local real_bar_len=$((${#bar_string} + ${#partial_block}))
    local empty_bar_len=$((width - real_bar_len))
    local empty_bar="" # Start with an empty string for the empty part of the bar
    for ((i = 0; i < empty_bar_len; i++)); do
        # Fill the empty part of the bar with full blocks
        # We will use gray color for the empty part
        empty_bar+=${blocks[8]}
    done

    local percentage=$((current * 100 / total))

    local color_bar_fg='\e[32m'     # Green foreground for the filled part
    local color_trail_fg='\e[90m'   # Dim grey foreground for the trail
    local color_trail_bg='\e[100m'  # Dim grey BACKGROUND for the trail
    local color_nc='\e[0m'          # No Color (reset)
    # Print the progress bar with spinner and colors
    printf "\r${spinner_char} │${color_trail_bg}${color_bar_fg}%s%s${color_trail_fg}%s${color_nc}│ %3d%% %s" \
        "$bar_string" \
        "$partial_block" \
        "$empty_bar" \
        "$percentage" \
        "$extra_text"
}

construct_extra_text() {
    local -n _extra_text_ref="$1" # Nameref to the caller's variable
    local files_completed_and_processing=$2 # Number of Files completed and currently processing
    local files_completed=$3 # Number of Files completed
    local total_files=$4 # Total number of files
    local in_progress_files=$((files_completed_and_processing - $files_completed))
    local in_queue_files=$(($total_files - $files_completed_and_processing))

    _extra_text_ref=$(printf "📁 %s ▶ ⚙️ %s ▶ ⏳ %s ▶ ✅ %s" \
        "${total_files}" \
        "${in_queue_files}" \
        "${in_progress_files}" \
        "${#completed_files[@]}"
    )
}

print_status() {
    local total_duration_secs=$1
    local -A file_durations=()
    local -A completed_files=()
    local extra_text=""
    construct_extra_text extra_text ${#file_durations[@]} ${#completed_files[@]} ${#expanded_files[@]}
    print_progress_bar 0 $total_duration_secs "$extra_text"

    while read -r secs status input_file; do
        if [[ -f "$SHUTTING_DOWN_FLAG_FILE" ]]; then
            printf "⏹️ Shutdown signaled. Exiting status monitor.\n" >&2
            break
        fi
        file_durations["$input_file"]=$secs
        if [[ "$status" == "end" ]]; then
            completed_files["$input_file"]=1
        fi
        local elapsed_secs=0
        for file in "${!file_durations[@]}"; do
            elapsed_secs=$((${file_durations[$file]} + elapsed_secs))
        done
        construct_extra_text extra_text ${#file_durations[@]} ${#completed_files[@]} ${#expanded_files[@]}
        print_progress_bar elapsed_secs total_duration_secs "$extra_text"
    done <&4
}

main() {
    parse_script_arguments "$@"
    prepare_file_list
    local empty_array=()
    construct_extra_text extra_text 0 0 ${#expanded_files[@]}
    print_progress_bar 0 1 "$extra_text"
    calculate_total_duration total_duration_secs
    init_semaphore
    mkdir -p "$PROGRESS_DIR" || {
        echo "Error: Failed to create progress directory!" >&2
        cleanup 1
    }
    local status_fifo=$(mktemp -u "${SEMAPHORE_DIR}/status.XXXXXXXXXX")
    mkfifo -m 600 "$status_fifo" || {
        echo "Error: Failed to create status FIFO!" >&2
        cleanup 1
    }
    exec 4<>"$status_fifo" # Open status FIFO for read/write
    do_reencoding encoding_job_pids
    print_status $total_duration_secs & # Start status printing in the background
    wait "${encoding_job_pids[@]}" # Wait for all encoding jobs to finish
    exec 4>&- # Close the status FIFO
    printf "🎉 All conversions completed!\n"
}

# Set up cleanup trap - exit with exit code 0 on normal exit, 1 on error
trap 'cleanup' EXIT
trap 'cleanup 1' INT TERM

main "$@"
