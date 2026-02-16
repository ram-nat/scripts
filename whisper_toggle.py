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
    # 1. Create lock
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))
    
    notify("Recording... (Press again to stop)")
    
    # 2. Record using arecord
    # -q: Quiet mode
    cmd = ["arecord", "-f", "S16_LE", "-c", "1", "-r", "16000", "-q", AUDIO_FILE]
    
    try:
        # We use Popen so we can wait specifically for this process
        process = subprocess.Popen(cmd)
        process.wait()
    except KeyboardInterrupt:
        pass

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
        
        # Send SIGINT (Ctrl+C) to arecord to make it save the file properly
        os.system("pkill -SIGINT arecord")
        
        # Clean up lock
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
