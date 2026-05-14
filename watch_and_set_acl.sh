#!/bin/bash

if [ $# -ne 2 ]; then
    echo "Usage: $0 <watch_dir> <user>"
    exit 1
fi

WATCH_DIR="$1"
USER_B="$2"

if [ ! -d "$WATCH_DIR" ]; then
    echo "Error: $WATCH_DIR is not a directory"
    exit 1
fi

# Initial setup - fix any existing files on startup
setfacl -R -m u:${USER_B}:rwX "$WATCH_DIR"
setfacl -R -d -m u:${USER_B}:rwx "$WATCH_DIR"
setfacl -R -d -m m::rwx "$WATCH_DIR"

# Watch for new files and directories
inotifywait -m -r -e create,moved_to "$WATCH_DIR" --format '%w%f %e' |
while read NEWITEM EVENT; do
    if [ ! -e "$NEWITEM" ]; then
        continue
    fi

    if [ -d "$NEWITEM" ]; then
        setfacl -m u:${USER_B}:rwx "$NEWITEM" 2>/dev/null
        setfacl -d -m u:${USER_B}:rwx "$NEWITEM" 2>/dev/null
        setfacl -d -m m::rwx "$NEWITEM" 2>/dev/null
    else
        setfacl -m u:${USER_B}:rw "$NEWITEM" 2>/dev/null
    fi
done
