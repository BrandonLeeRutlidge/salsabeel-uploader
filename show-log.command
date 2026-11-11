#!/bin/bash
# Opens the uploader's log: what it moved and uploaded, and when.
LOG="$HOME/Library/Logs/SalsabeelLiveUploader.log"
if [ -f "$LOG" ]; then open -e "$LOG"; else echo "No log yet: the uploader has not done anything so far."; fi
