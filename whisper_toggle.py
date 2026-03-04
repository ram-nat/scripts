import os
import sys
import subprocess
import time
import signal
from faster_whisper import WhisperModel

# --- CONFIGURATION ---
MODEL_SIZE = "base"
DEVICE = "cpu"
COMPUTE_TYPE = "int8"
LOCK_FILE = "/tmp/whisper_lock"
AUDIO_FILE = "/tmp/whisper_audio.wav"

def notify(message):
    print(f"🔔 {message}")
    subprocess.run(["notify-send", "-t", "1000", "Whisper", message])

def start_recording():
    # 1. Create lock file immediately (with placeholder)
    with open(LOCK_FILE, "w") as f:
        f.write("pending")

    notify("Recording... (Press again to stop)")

    # 2. Record using arecord
    # -q: Quiet mode
    cmd = ["arecord", "-f", "S16_LE", "-c", "1", "-r", "16000", "-q", AUDIO_FILE]

    # We use Popen so we can wait specifically for this process
    process = subprocess.Popen(cmd)

    try:
        # Update lock file with the actual arecord PID
        # RC-2: if this write fails, terminate arecord before propagating
        with open(LOCK_FILE, "w") as f:
            f.write(str(process.pid))
    except OSError:
        process.terminate()
        process.wait()
        raise

    try:
        process.wait()
    except KeyboardInterrupt:
        # RC-1: Python wrapper was interrupted directly (e.g. kill -INT on the
        # Python PID, not the whole process group).  arecord is still running —
        # kill it explicitly so it doesn't become an orphan.
        process.terminate()
        process.wait()

def stop_and_transcribe():
    # 1. STOPPING
    # Give the OS a moment to flush the WAV header to disk
    time.sleep(0.5)
    
    if not os.path.exists(AUDIO_FILE):
        notify("❌ Error: Audio file missing.")
        return

    vocab_path = os.path.expanduser("~/whisper-tool/vocab.txt")
    rams_vocab = ""
    if os.path.exists(vocab_path):
        with open(vocab_path, "r") as f:
            # Join lines and remove extra whitespace to create a clean hint string
            rams_vocab = ", ".join([line.strip() for line in f if line.strip()])    

    notify("Transcribing...")

    try:
        # 2. TRANSCRIBING
        # We load the model fresh each time (slower start, but saves RAM when idle)
        model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
        
        segments, _ = model.transcribe(
            AUDIO_FILE, 
            beam_size=1,
            language="en",                 # <--- FORCE ENGLISH
            vad_filter=True,               # <--- IGNORE SILENCE
            initial_prompt=rams_vocab,       # <--- VOCAB HINTS
            condition_on_previous_text=False
        )
        
        text = " ".join([segment.text for segment in segments]).strip()
        
        if text:
            print(f"📝 RESULT: {text}")
            # We explicitly pass the YDOTOOL_SOCKET in case the hotkey environment lacks it
            env = os.environ.copy()
            env["YDOTOOL_SOCKET"] = f"{os.environ['HOME']}/.ydotool_socket"
            
           
            # Small delay for keyboard release
            time.sleep(0.1)
            
            # Paste using ydotool
            try:
                subprocess.run(["ydotool", "type", "--delay", "2", text + " "], env=env, check=True)
            except subprocess.CalledProcessError as e:
                print(f"❌ ydotool type failed: {e}")            
        else:
            notify("⚠️ No speech detected.")
            
    except Exception as e:
        notify(f"❌ Error: {e}")

def main():
    if os.path.exists(LOCK_FILE):
        # --- STOP SIGNAL ---
        print("🛑 Stop signal received. Finishing recording...")
        
        # Read the PID of the arecord process we started
        try:
            with open(LOCK_FILE, "r") as f:
                arecord_pid = int(f.read().strip())
            
            # Send SIGINT (Ctrl+C) to our specific arecord process to make it save the file properly
            os.kill(arecord_pid, signal.SIGINT)
        except (FileNotFoundError, ProcessLookupError):
            # Process is dead or lock file gone — stale state, fall through to cleanup
            pass
        except ValueError:
            # RC-3: "pending" race — PID not written yet; spin-wait briefly for it.
            # The first invocation needs only a few ms to write the real PID after Popen.
            deadline = time.monotonic() + 1.0
            arecord_pid = None
            while time.monotonic() < deadline:
                time.sleep(0.05)
                try:
                    with open(LOCK_FILE, "r") as f:
                        arecord_pid = int(f.read().strip())
                    os.kill(arecord_pid, signal.SIGINT)
                    break
                except (ValueError, FileNotFoundError, ProcessLookupError):
                    pass
            if arecord_pid is None:
                print("⚠️ Could not stop recording; please try again.")
                return
        
        # Clean up lock (only reached on success or stale state)
        if os.path.exists(LOCK_FILE):
            os.remove(LOCK_FILE)
    else:
        # --- START SIGNAL ---
        try:
            start_recording()
            # Script pauses here until arecord is killed by the second instance
            
            # Once killed, we proceed:
            stop_and_transcribe()
        finally:
            if os.path.exists(LOCK_FILE):
                os.remove(LOCK_FILE)

if __name__ == "__main__":
    main()
