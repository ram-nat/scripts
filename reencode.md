This file, reencode.sh, is a Zsh shell script designed for batch re-encoding of MKV video files, with a focus on making them compatible with Plex while preserving HDR (High Dynamic Range) metadata and normalizing the AC3 audio track.

### Key Features

- **Batch Processing:**  
  Accepts one or more MKV files, or a directory containing MKV files, and processes them all.

- **Parallelization (Semaphore Control):**  
  Uses a custom semaphore mechanism to limit the number of concurrent ffmpeg jobs (default: 4), which is important for hardware-accelerated encoding on NVIDIA GPUs that have session limits.

- **HDR Preservation:**  
  Detects if the input video is HDR (HDR10/PQ or HLG) using ffprobe, and passes appropriate color metadata and pixel format options to ffmpeg to preserve HDR in the output.

- **Audio Normalization:**  
  Normalizes the first audio track to broadcast loudness standards using ffmpeg's loudnorm filter.  
  Supports optional two-pass normalization (with --two-pass), which is more accurate.

- **Dual Audio Tracks:**  
  The output MKV contains both the original audio (copied) and a normalized AC3 audio track at 640k bitrate.

- **Graceful Shutdown and Cleanup:**  
  Handles interrupts (Ctrl+C) and cleans up temporary files, semaphore FIFOs, and terminates child jobs properly.

- **Usage Example:**  
  ```
  ./reencode.sh [--two-pass] input1.mkv input2.mkv ...
  ./reencode.sh [--two-pass] /path/to/directory/
  ```

### Workflow Summary

1. **Checks for required dependencies** (ffmpeg and ffprobe).
2. **Parses input arguments** for files/directories and --two-pass option.
3. **Expands directories** into lists of MKV files.
4. **Initializes a semaphore** to control parallel jobs.
5. **For each file:**
   - Detects video color properties for HDR handling.
   - Runs ffmpeg to:
     - Hardware-decode the video and re-encode with NVENC (HEVC).
     - Copy the original audio and add a loudness-normalized AC3 audio track.
     - Copy subtitles.
     - Preserve HDR/SDR color metadata.
6. **Runs jobs in the background** up to the max limit, showing status and final results.

### When to Use

- Preparing a library of MKV files for Plex streaming, especially when you want:
  - Hardware-accelerated encoding (NVIDIA GPU required).
  - HDR video preservation.
  - Proper, consistent loudness in audio tracks.
  - Efficient batch processing with controlled concurrency.

If you have specific questions about how parts of the script work, or need usage advice, let me know!
