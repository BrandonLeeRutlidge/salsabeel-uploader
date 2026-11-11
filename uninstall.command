#!/bin/bash
# Salsabeel live uploader: stop it running. Recordings and Google Drive are left as they are.
LABEL="com.salsabeel.live-uploader"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/.salsabeel-uploader"   # its hidden backup copy, or it would put itself back
echo "The uploader is stopped and will not start again."
echo "Anything still in the \"Ready to upload\" folder was not uploaded; it is still on this Mac."
echo "To remove the Google sign-in as well, run in Terminal:  rclone config delete salsabeel-drive"
