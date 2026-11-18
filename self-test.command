#!/bin/bash
# Checks the uploader works on this Mac, with test folders and a test "Google Drive" folder on this
# Mac. The installer runs it at the end. It needs no Google sign-in, and it changes nothing else.
cd "$(dirname "$0")" || exit 1
RCLONE=""
for p in "$HOME/Library/Application Support/SalsabeelLiveUploader/bin/rclone" "$(command -v rclone || true)" \
         /opt/homebrew/bin/rclone /usr/local/bin/rclone; do
    if [ -n "$p" ] && [ -x "$p" ]; then RCLONE="$p"; break; fi
done
if [ -z "$RCLONE" ]; then echo "rclone is not set up yet: run \"Fix Salsabeel uploader\" first."; exit 1; fi

ROOT=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/salsabeel-uploader-test.XXXXXX")" && pwd -P)   # real path: /var is /private/var on a Mac
trap 'rm -rf "$ROOT"' EXIT
REC="$ROOT/Recordings"
DRIVE="$ROOT/Google Drive/Salsabeel lives"
mkdir -p "$REC" "$DRIVE" "$ROOT/app"
export SALSABEEL_UPLOADER_DIR="$ROOT/app" SALSABEEL_UPLOADER_LOG="$ROOT/test.log"
export SALSABEEL_UPLOADER_TEMPLATE="$PWD/status-page.html"
export HOME="$ROOT/home"                          # its backup copy and background job file stay in the test folder
export SALSABEEL_UPLOADER_RECORDER="fakerec$$x"  # only the test's pretend LIVE Studio counts, never the real one
export SALSABEEL_UPLOADER_MIN_LIVE_MB=0           # the test videos are tiny; one check below sets a size
export SALSABEEL_UPLOADER_TEST=1                  # it may follow recordings in temporary folders (where this test works)
export SALSABEEL_UPLOADER_PING="$ROOT/fake-ping" SALSABEEL_UPLOADER_PING_HOSTS=testhost   # never the real internet
mkdir -p "$HOME"
cat > "$ROOT/fake-ping" <<EOF
#!/bin/bash
# A pretend ping: each call takes the next "delay lost" line from ping-seq (the last one repeats).
f="$ROOT/ping-seq"; v="20 0"
if [ -s "\$f" ]; then
    v=\$(head -n 1 "\$f")
    if [ "\$(wc -l < "\$f")" -gt 1 ]; then tail -n +2 "\$f" > "\$f.n"; mv -f "\$f.n" "\$f"; fi
fi
set -- \$v
for i in 1 2 3 4 5; do [ "\$i" -le "\${2:-0}" ] || echo "64 bytes from 10.0.0.1: icmp_seq=\$i ttl=57 time=\$1 ms"; done
EOF
chmod +x "$ROOT/fake-ping"
printf '#!/bin/bash\necho opened >> "%s"\n' "$ROOT/opened" > "$ROOT/fake-open"; chmod +x "$ROOT/fake-open"
export SALSABEEL_UPLOADER_OPEN="$ROOT/fake-open"     # count the times the status page would pop up
PAGE="$ROOT/app/Salsabeel live uploader.html"
opened() { [ -f "$ROOT/opened" ] && wc -l < "$ROOT/opened" | tr -d ' ' || echo 0; }
setup() {   # destination [extra config lines]
    printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$1" "$RCLONE" > "$ROOT/app/config.sh"
    if [ $# -gt 1 ]; then printf '%s\n' "$2" >> "$ROOT/app/config.sh"; fi
}
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
ago() {   # touch a file so it was last changed $2 minutes ago
    local t=$(( $(date +%s) - $2 * 60 ))
    if [ "$(uname)" = "Darwin" ]; then touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"; else touch -d "@$t" "$1"; fi
}
agos() {   # the same, in seconds
    local t=$(( $(date +%s) - $2 ))
    if [ "$(uname)" = "Darwin" ]; then touch -t "$(date -r "$t" +%Y%m%d%H%M.%S)" "$1"; else touch -d "@$t" "$1"; fi
}
fails=0
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails + 1)); fi; }
count() { find "$1" -maxdepth 1 -type f -name "$2" | wc -l | tr -d ' '; }
fsize_of() { if [ "$(uname)" = "Darwin" ]; then stat -f %z "$1"; else stat -c %s "$1"; fi; }
mtime_of() { if [ "$(uname)" = "Darwin" ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
NOTE="$DRIVE/Uploader checks/Mac status.txt"
now_is() { grep -qxF "Now:                $2" "$1"; }   # note "sentence": the note's Now: line, word for word

echo "Salsabeel live uploader: self-test"
head -c 4096 /dev/zero > "$REC/record_finished.mp4";  ago "$REC/record_finished.mp4" 10
head -c 4096 /dev/zero > "$REC/record_live.mp4";      ago "$REC/record_live.mp4" 10
head -c 4096 /dev/zero > "$REC/record_just_stopped.mov"; agos "$REC/record_just_stopped.mov" 100
echo "notes" > "$REC/notes.txt"
mkdir -p "$REC/Ready to upload"; echo x > "$REC/Ready to upload/.DS_Store"

exec 3>>"$REC/record_live.mp4"          # held open, as LIVE Studio does while it records
setup "$DRIVE"
bash ./upload-lives.sh
exec 3>&-

check "a finished recording reaches Google Drive with a date-and-time name" \
      '[ "$(count "$DRIVE" "Salsabeel live ????-??-?? ??-??.mp4")" = 1 ]'
check "it is gone from the recording folder" '[ ! -e "$REC/record_finished.mp4" ]'
check "a recording still in progress is left alone" '[ -e "$REC/record_live.mp4" ]'
check "a recording that only just stopped waits a few minutes" '[ -e "$REC/record_just_stopped.mov" ]'
check "a file that is not a video is left alone" '[ -e "$REC/notes.txt" ]'
check "hidden Mac files are not uploaded" '[ "$(count "$DRIVE" ".*")" = 0 ]'
check "the status page popped up when the live finished" '[ "$(opened)" = 1 ]'
check "the status page ends on \"done\" and stops refreshing" \
      'grep -q "The live is in Google Drive" "$PAGE" && ! grep -q "http-equiv=\"refresh\"" "$PAGE"'
rm -f "$REC/record_live.mp4"            # the "live" has stopped; clear it so the counts below stay simple

head -c 4096 /dev/zero > "$REC/again_a.mp4"; ago "$REC/again_a.mp4" 10
head -c 4096 /dev/zero > "$REC/again_b.mp4"; ago "$REC/again_b.mp4" 10
printf '[offline]\ntype = http\nurl = http://127.0.0.1:9/\n' > "$ROOT/offline.conf"
setup "offline:Salsabeel lives"   # signed in, but Google Drive can't be reached
rm -f "$ROOT/app/status-sent"
RCLONE_CONFIG="$ROOT/offline.conf" bash ./upload-lives.sh 2>/dev/null
check "when the upload fails, the recordings wait in \"Ready to upload\"" \
      '[ "$(count "$REC/Ready to upload" "Salsabeel live *.mp4")" = 2 ]'
check "the page says it is waiting, tells them to leave the Mac on, and keeps refreshing" \
      'grep -q "Waiting for the internet" "$PAGE" && grep -q "leave the Mac on" "$PAGE" && grep -q "http-equiv=\"refresh\"" "$PAGE"'
check "offline: the note's Now line says \"Waiting for the internet\"" \
      'now_is "$ROOT/app/Mac status.txt" "Waiting for the internet"'
setup "$DRIVE"
bash ./upload-lives.sh; bash ./upload-lives.sh             # one file per run, oldest first
check "the next tries upload them, one at a time, and two recordings never share a name" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = 3 ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ]'
check "a retry does not pop the page up again (it is already open)" '[ "$(opened)" = 2 ]'
echo stale > "$ROOT/app/page-opened-boot"; head -c 4096 /dev/zero > "$REC/Ready to upload/after-restart.mp4"
bash ./upload-lives.sh
check "after a restart mid-upload, the page pops up again" '[ "$(opened)" = 3 ]'

check "a status note for Brandon is in Google Drive, with the end of the log" \
      'grep -q "Waiting to upload:  0" "$DRIVE/Uploader checks/Mac status.txt" && grep -q "Uploading" "$DRIVE/Uploader checks/Mac status.txt"'
check "the note has a Now line straight after Sent, padded like the rest: \"Nothing to upload\"" \
      'grep -A1 "^Sent: " "$NOTE" | tail -n 1 | grep -qx "Now:                Nothing to upload"'
agos "$ROOT/app/status-sent" 360
bash ./upload-lives.sh
check "nothing happening: the note waits 30 minutes (not sent again after 6)" \
      '[ "$(mtime_of "$ROOT/app/status-sent")" -lt $(( $(date +%s) - 300 )) ]'

# Looking after itself
rm -rf "$REC"
bash ./upload-lives.sh
check "if someone moves or deletes the recording folder, it is made again" '[ -d "$REC" ]'
mkdir -p "$REC/2026-11-11"; head -c 4096 /dev/zero > "$REC/2026-11-11/nested.mp4"; ago "$REC/2026-11-11/nested.mp4" 10
bash ./upload-lives.sh
check "a recording saved in a folder inside the recording folder is uploaded too" '[ ! -e "$REC/2026-11-11/nested.mp4" ] && [ "$(count "$DRIVE" "Salsabeel live *.mp4")" = 4 ]'
head -c 4096 /dev/zero > "$REC/old-holiday-video.mp4"; ago "$REC/old-holiday-video.mp4" 600
setup "$DRIVE" "ONLY_NEW_SINCE=$(( $(date +%s) - 3600 ))"
bash ./upload-lives.sh
check "with ONLY_NEW_SINCE, older videos already in the folder are left alone" '[ -e "$REC/old-holiday-video.mp4" ]'
rm -f "$REC/old-holiday-video.mp4"

# Updates from Brandon (a test "website" folder, read with curl's file://)
SITE="$ROOT/site"; mkdir -p "$SITE"
publish() {   # make a version on the test site: $1 = what the new script says when it runs
    sed "s|^set -u\$|set -u; echo \"$1\" >> \"$ROOT/ran\"|" upload-lives.sh > "$SITE/upload-lives.sh"
    cp status-page.html "$SITE/status-page.html"
    { echo "version $1"; for n in upload-lives.sh status-page.html; do echo "$(sha "$SITE/$n")  $n"; done; } > "$SITE/manifest.txt"
}
installed() { cp upload-lives.sh status-page.html "$ROOT/app/"; echo v0 > "$ROOT/app/VERSION"; rm -f "$ROOT/app/update-checked"; }
installed; setup "$DRIVE" "UPDATE_URL=file://$SITE"; publish v1
bash "$ROOT/app/upload-lives.sh"; bash "$ROOT/app/upload-lives.sh"
check "a new version on the website is picked up, and runs from the next minute" \
      '[ "$(cat "$ROOT/app/VERSION")" = v1 ] && [ "$(cat "$ROOT/ran" 2>/dev/null)" = v1 ]'
check "it is checked for every 10 minutes, not every minute" \
      '[ -f "$ROOT/app/update-checked" ] && publish v2 && agos "$ROOT/app/update-checked" 540 && bash "$ROOT/app/upload-lives.sh" && [ "$(cat "$ROOT/app/VERSION")" = v1 ] &&
       agos "$ROOT/app/update-checked" 610 && bash "$ROOT/app/upload-lives.sh" && [ "$(cat "$ROOT/app/VERSION")" = v2 ]'
installed; publish v3; echo "# changed after the manifest was made" >> "$SITE/upload-lives.sh"
bash "$ROOT/app/upload-lives.sh"
check "a download that does not match its checksum is not used" '[ "$(cat "$ROOT/app/VERSION")" = v0 ] && cmp -s upload-lives.sh "$ROOT/app/upload-lives.sh"'
installed; publish v4; printf 'if then\n' >> "$SITE/upload-lives.sh"
{ echo "version v4"; for n in upload-lives.sh status-page.html; do echo "$(sha "$SITE/$n")  $n"; done; } > "$SITE/manifest.txt"
bash "$ROOT/app/upload-lives.sh"
check "a broken script is not used, even with the right checksum" '[ "$(cat "$ROOT/app/VERSION")" = v0 ] && cmp -s upload-lives.sh "$ROOT/app/upload-lives.sh"'
installed; rm -rf "$SITE"; bash "$ROOT/app/upload-lives.sh"; status=$?
check "no website (offline): it carries on as it is" '[ "$status" = 0 ] && [ "$(cat "$ROOT/app/VERSION")" = v0 ]'
# Putting itself back when things are moved or deleted
setup "$DRIVE"; cp upload-lives.sh status-page.html "$ROOT/app/"
JOB="$HOME/Library/LaunchAgents/com.salsabeel.live-uploader.plist"
bash "$ROOT/app/upload-lives.sh"
check "it keeps a hidden backup copy, and writes its background job file" \
      '[ -f "$HOME/.salsabeel-uploader/upload-lives.sh" ] && [ -f "$HOME/.salsabeel-uploader/config.sh" ] && grep -q "<string>-c</string>" "$JOB"'
rm -f "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh"
check "its settings file deleted: put back from the backup" 'grep -q "^WATCH_DIR=" "$ROOT/app/config.sh"'
rm -f "$JOB"
bash "$ROOT/app/upload-lives.sh"
check "the background job file deleted: written again" '[ -f "$JOB" ]'
boot=$(awk '/<string>-c<\/string>/ { on = 1; next } on && /<\/array>/ { on = 0 } on' "$JOB" |
       sed -e '1s/^ *<string>//' -e '$s/<\/string>$//' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')
rm -rf "$ROOT/app"
head -c 4096 /dev/zero > "$REC/after_folder_deleted.mp4"; ago "$REC/after_folder_deleted.mp4" 10
bash -c "$boot"
check "its whole folder deleted: the background job puts it back and carries on uploading" \
      '[ -f "$ROOT/app/upload-lives.sh" ] && [ -f "$ROOT/app/config.sh" ] && [ ! -e "$REC/after_folder_deleted.mp4" ]'

printf '[testdrive]\ntype = alias\nremote = %s\n' "$ROOT/Google Drive" > "$ROOT/rclone.conf"
export RCLONE_CONFIG="$ROOT/rclone.conf"
setup "testdrive:Salsabeel lives"
bash "$ROOT/app/upload-lives.sh"
check "the Google sign-in is in the backup copy" 'grep -q "^\[testdrive\]" "$HOME/.salsabeel-uploader/rclone.conf"'
rm -f "$ROOT/rclone.conf"
head -c 4096 /dev/zero > "$REC/after_signin_lost.mp4"; ago "$REC/after_signin_lost.mp4" 10
bash "$ROOT/app/upload-lives.sh"
check "the Google sign-in deleted: put back, and uploads carry on" \
      'grep -q "^\[testdrive\]" "$ROOT/rclone.conf" && [ ! -e "$REC/after_signin_lost.mp4" ]'
unset RCLONE_CONFIG
setup "$DRIVE"

mkdir -p "$ROOT/fakerec$$x" "$ROOT/elsewhere"
printf '#!/bin/bash\nexec 3>>"%s"\nwhile :; do sleep 1 3>&-; done\n' "$ROOT/elsewhere/live.mp4" > "$ROOT/fakerec$$x/rec"
bash "$ROOT/fakerec$$x/rec" & recpid=$!
sleep 1; head -c 4096 /dev/zero >> "$ROOT/elsewhere/live.mp4"   # (growing: written just now)
bash "$ROOT/app/upload-lives.sh"
check "LIVE Studio recording somewhere else: it notices, and leaves it alone while it records" \
      'grep -qxF "$ROOT/elsewhere/live.mp4" "$ROOT/app/following" && [ -e "$ROOT/elsewhere/live.mp4" ]'
kill "$recpid"; wait "$recpid" 2>/dev/null; sleep 1; ago "$ROOT/elsewhere/live.mp4" 10
bash "$ROOT/app/upload-lives.sh"
check "once that recording stops, it is uploaded too" '[ ! -e "$ROOT/elsewhere/live.mp4" ] && [ ! -s "$ROOT/app/following" ]'

# Scene media LIVE Studio merely holds open (an intro clip, a looping background) is not a live
mkdir -p "$ROOT/scene"; head -c 4096 /dev/zero > "$ROOT/scene/intro.mp4"; ago "$ROOT/scene/intro.mp4" 30
printf '#!/bin/bash\nexec 3<"%s"\nwhile :; do sleep 1 3>&-; done\n' "$ROOT/scene/intro.mp4" > "$ROOT/fakerec$$x/rec"
bash "$ROOT/fakerec$$x/rec" & recpid=$!; sleep 1
head -c 4096 /dev/zero > "$REC/during_break.mp4"; ago "$REC/during_break.mp4" 10
before=$(count "$DRIVE" "Salsabeel live *.mp4"); : > "$ROOT/test.log"
bash "$ROOT/app/upload-lives.sh"
check "LIVE Studio holding a still video open (scene media, in a break) is not a live: it uploads at full speed" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = $((before + 1)) ] && ! grep -qE "Live started|A live is" "$ROOT/test.log" && ! grep -qF intro.mp4 "$ROOT/app/following" 2>/dev/null && [ -e "$ROOT/scene/intro.mp4" ]'
kill "$recpid"; wait "$recpid" 2>/dev/null

MOVED="$HOME/Movies/Old stuff/Salsabeel lives/Recordings/Ready to upload"
mkdir -p "$MOVED" "$HOME/Desktop/Salsabeel lives/Recordings"
head -c 4096 /dev/zero > "$MOVED/Salsabeel live 2026-11-08 18-02.mp4"; ago "$MOVED/Salsabeel live 2026-11-08 18-02.mp4" 10
head -c 4096 /dev/zero > "$HOME/Desktop/Salsabeel lives/Recordings/x.mp4"; ago "$HOME/Desktop/Salsabeel lives/Recordings/x.mp4" 10
rm -f "$ROOT/app/moved-checked"; before=$(count "$DRIVE" "Salsabeel live *.mp4")
bash "$ROOT/app/upload-lives.sh"
check "a moved \"Salsabeel lives\" folder: what was left in it is uploaded" \
      '[ ! -e "$MOVED/Salsabeel live 2026-11-08 18-02.mp4" ] && [ "$(count "$DRIVE" "Salsabeel live *.mp4")" -gt "$before" ]'
check "it never looks in Desktop, Documents or Downloads by itself (so macOS never asks)" \
      '[ -e "$HOME/Desktop/Salsabeel lives/Recordings/x.mp4" ]'

# A live on: uploads wait, and an upload already running stops
head -c 4096 /dev/zero > "$REC/finished_earlier.mp4"; ago "$REC/finished_earlier.mp4" 10
head -c 4096 /dev/zero > "$REC/live_now.mp4"            # being written right now
before=$(count "$DRIVE" "Salsabeel live *.mp4")
rm -f "$ROOT/app/status-sent"
setup "$DRIVE" 'LIVE_UPLOAD=off'
bash "$ROOT/app/upload-lives.sh"
check "LIVE_UPLOAD=off: while a live is recording, nothing uploads (the stream keeps the internet)" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = "$before" ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && [ -f "$ROOT/app/paused" ]'
check "a live on: the note says \"A live is on: 1 upload waits until it stops\"" \
      'now_is "$NOTE" "A live is on: 1 upload waits until it stops"'
agos "$ROOT/app/status-sent" 360; head -c 1 /dev/zero >> "$REC/live_now.mp4"
bash "$ROOT/app/upload-lives.sh"
check "a live on: the note goes again after 5 minutes (not 30)" \
      '[ "$(mtime_of "$ROOT/app/status-sent")" -ge $(( $(date +%s) - 60 )) ]'
ago "$REC/live_now.mp4" 10                               # the live has ended
bash "$ROOT/app/upload-lives.sh"; bash "$ROOT/app/upload-lives.sh"
check "once the recording stops, the uploads carry on" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = $((before + 2)) ] && [ ! -f "$ROOT/app/paused" ]'
head -c 4096 /dev/zero > "$REC/big.mp4"; ago "$REC/big.mp4" 10
printf '#!/bin/bash\nif [ "$1" = move ]; then sleep 60; fi\nexec %q "$@"\n' "$RCLONE" > "$ROOT/slow-rclone"   # a slow internet
chmod +x "$ROOT/slow-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nLIVE_UPLOAD=off\n' "$REC" "$DRIVE" "$ROOT/slow-rclone" > "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 4; head -c 4096 /dev/zero > "$REC/live_again.mp4"   # a live starts mid-upload
for i in $(seq 1 40); do grep -q "upload is paused until it ends" "$ROOT/test.log" && break; head -c 1 /dev/zero >> "$REC/live_again.mp4"; sleep 1; done
check "LIVE_UPLOAD=off: an upload already running pauses when a live starts (it is not stopped or started again)" \
      'kill -0 "$up" 2>/dev/null && [ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && grep -q "A live started: the upload is paused until it ends (what it has sent is kept)" "$ROOT/test.log"'
ago "$REC/live_again.mp4" 10; mv "$REC/live_again.mp4" "$ROOT/live_again.mp4"   # the live ends
for i in $(seq 1 180); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
check "after the live the same upload carries on and finishes" \
      '! kill -0 "$up" 2>/dev/null && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ] && grep -q "The recording has stopped: the upload carries on" "$ROOT/test.log" && [ "$(grep -c "^.*  Uploading " "$ROOT/test.log")" -ge 1 ]'
kill "$up" 2>/dev/null; rm -f "$ROOT/live_again.mp4"; setup "$DRIVE"

# Brandon's PC has copied a live ("Copied - ..."): it is deleted here; the others stay
head -c 4096 /dev/zero > "$DRIVE/Copied - Salsabeel live 2026-11-09 18-00.mp4"
head -c 4096 /dev/zero > "$DRIVE/Salsabeel live 2026-11-10 18-00.mp4"
rm -f "$ROOT/app/cleared-checked"
bash "$ROOT/app/upload-lives.sh"
check "a live Brandon's PC has copied is deleted from this Drive, and nothing else" \
      '[ ! -e "$DRIVE/Copied - Salsabeel live 2026-11-09 18-00.mp4" ] && [ -e "$DRIVE/Salsabeel live 2026-11-10 18-00.mp4" ]'
bash "$ROOT/app/upload-lives.sh" --status-now
check "the status note says how many lives wait in Drive for the cloud" \
      'grep -q "not yet taken by the cloud: [1-9]" "$DRIVE/Uploader checks/Mac status.txt"'

# Google Drive full: the page says so (not "waiting for the internet")
printf '#!/bin/bash\nif [ "$1" = move ]; then for a in "$@"; do [ -n "${next:-}" ] && echo "ERROR : googleapi: Error 403: The user'"'"'s Drive storage quota has been exceeded., storageQuotaExceeded" >> "$a"; next=; [ "$a" = --log-file ] && next=1; done; exit 1; fi\nexec %q "$@"\n' "$RCLONE" > "$ROOT/full-rclone"
chmod +x "$ROOT/full-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$DRIVE" "$ROOT/full-rclone" > "$ROOT/app/config.sh"
head -c 4096 /dev/zero > "$REC/when_full.mp4"; ago "$REC/when_full.mp4" 10
bash "$ROOT/app/upload-lives.sh"
check "Google Drive full: the live waits on the Mac, and the page says Drive is full" \
      '[ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && grep -q "Google Drive is full" "$PAGE" && grep -q "Google Drive is full" "$ROOT/test.log"'
check "Google Drive full: the note says \"Google Drive is full: 1 live waits on the Mac\"" \
      'now_is "$NOTE" "Google Drive is full: 1 live waits on the Mac"'
setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

# A short recording is a test, not a live: it goes beside the status note, never with the lives
before=$(count "$DRIVE" "Salsabeel live *.mp4")
head -c 4096 /dev/zero > "$REC/quick_test.mp4"; ago "$REC/quick_test.mp4" 10
setup "$DRIVE" 'MIN_LIVE_MB=1'
bash "$ROOT/app/upload-lives.sh"
check "a short test recording goes to Uploader checks/Short recordings, not with the lives" \
      '[ "$(count "$DRIVE/Uploader checks/Short recordings" "Short recording *.mp4")" = 1 ] && [ "$(count "$DRIVE" "Salsabeel live *.mp4")" = "$before" ]'
setup "$DRIVE"

# A new version mid-upload at full speed: installed, but the upload is never stopped for it
SITE="$ROOT/site"; mkdir -p "$SITE"; publish v9
head -c 4096 /dev/zero > "$REC/long_upload.mp4"; ago "$REC/long_upload.mp4" 10
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=%q\nUPDATE_EVERY=20\n' "$REC" "$DRIVE" "$ROOT/slow-rclone" "file://$SITE" > "$ROOT/app/config.sh"
echo v8 > "$ROOT/app/VERSION"; touch "$ROOT/app/update-checked"
bash "$ROOT/app/upload-lives.sh" & up=$!
for i in $(seq 1 90); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
check "a new version mid-upload is installed, and the upload carries on to the end (not started again)" \
      '! kill -0 "$up" 2>/dev/null && [ "$(cat "$ROOT/app/VERSION")" = v9 ] && grep -q "takes over after this upload (the upload carries on)" "$ROOT/test.log" && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ]'
kill "$up" 2>/dev/null; cp upload-lives.sh "$ROOT/app/upload-lives.sh"; setup "$DRIVE"
bash "$ROOT/app/upload-lives.sh"

# Google Drive nearly full: only what fits goes up, oldest first; nothing is sent when nothing fits
cat > "$ROOT/small-rclone" <<EOF
#!/bin/bash
if [ "\$1" = about ]; then echo "{\"total\":15000,\"free\":\$(cat "$ROOT/drive-free")}"; exit 0; fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/small-rclone"
printf '[testdrive]\ntype = alias\nremote = %s\n' "$ROOT/Google Drive" > "$ROOT/rclone.conf"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nDRIVE_MARGIN_MB=0\n' "$REC" "testdrive:Salsabeel lives" "$ROOT/small-rclone" > "$ROOT/app/config.sh"
echo 6000 > "$ROOT/drive-free"
head -c 4096 /dev/zero > "$REC/older.mp4"; agos "$REC/older.mp4" 900
head -c 4096 /dev/zero > "$REC/newer.mp4"; agos "$REC/newer.mp4" 600
before=$(count "$DRIVE" "Salsabeel live *.mp4")
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
check "Drive nearly full: only what fits is uploaded, and the other waits" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = $((before + 1)) ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ]'
check "one uploaded, one waiting: the note says so (not \"Drive is full\")" \
      'now_is "$NOTE" "Uploaded one: 1 live waits, the next starts within a minute"'
echo 100 > "$ROOT/drive-free"
agos "$ROOT/app/status-sent" 360
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
check "nothing fits: nothing is sent, and the page says Drive is full" \
      '[ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && grep -q "Google Drive is full" "$PAGE" && grep -q "wait on this Mac until there is room" "$ROOT/test.log"'
check "Drive full: the note goes again after 5 minutes, and says so" \
      '[ "$(mtime_of "$ROOT/app/status-sent")" -ge $(( $(date +%s) - 60 )) ] && now_is "$NOTE" "Google Drive is full: 1 live waits on the Mac"'
setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

# Mid-upload: the note goes up from the progress loop, in the background, with the progress in it
cat > "$ROOT/progress-rclone" <<EOF
#!/bin/bash
if [ "\$1" = copyto ]; then sleep 3; fi    # a slow note must not hold up the progress loop
if [ "\$1" = move ]; then
    trap ':' USR2   # (like rclone: SIGUSR2 toggles its speed limit; it does not stop it)
    for a in "\$@"; do [ -n "\${next:-}" ] && log="\$a"; next=; [ "\$a" = --log-file ] && next=1; done
    echo "2026/11/11 12:00:00 NOTICE:    2.384 GiB / 5.678 GiB, 42%, 10.000 MiB/s, ETA 6m12s" >> "\$log"
    sleep 12
fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/progress-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$DRIVE" "$ROOT/progress-rclone" > "$ROOT/app/config.sh"
head -c 4096 /dev/zero > "$REC/watched.mp4"; ago "$REC/watched.mp4" 10
agos "$ROOT/app/status-sent" 360
bash "$ROOT/app/upload-lives.sh" & up=$!
for i in $(seq 1 10); do sleep 1; now_is "$NOTE" "Uploading 42% (2.4 GB of 5.7 GB, about 6 minutes left)" && break; done
check "mid-upload: the note goes up while it uploads, with \"Uploading 42% (2.4 GB of 5.7 GB, about 6 minutes left)\"" \
      'kill -0 "$up" 2>/dev/null && now_is "$NOTE" "Uploading 42% (2.4 GB of 5.7 GB, about 6 minutes left)"'
check "mid-upload: the page kept updating while the note went up" 'grep -q "Uploading 42%" "$PAGE"'
wait "$up"
check "after the upload, the note says \"Nothing to upload\"" \
      'now_is "$NOTE" "Nothing to upload" && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ]'
setup "$DRIVE"

# Uploading during a live: slowly, watching the line, and never the live recording itself
cat > "$ROOT/trickle-rclone" <<EOF
#!/bin/bash
if [ "\$1" = move ]; then exec "$RCLONE" "\$@" --disable Move; fi   # copy for real, so the speed cap shows
if [ "\$1" = rc ]; then   # like newer rclone (the Mac's): changing the speed needs a login
    case " \$* " in *" --user salsabeel --pass "*) ;; *)
        echo 'Failed to rc: operation "core/bwlimit" failed: authentication must be set up on the rc server to use "core/bwlimit"' >&2; exit 1 ;; esac
fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/trickle-rclone"
trickle_setup() { printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n%s\n' "$REC" "$DRIVE" "$ROOT/trickle-rclone" "$1" > "$ROOT/app/config.sh"; }
start_live() {   # a pretend LIVE Studio, recording to $REC/on_air.mp4
    head -c 4096 /dev/zero > "$REC/on_air.mp4"; ago "$REC/on_air.mp4" 10
    printf '#!/bin/bash\nexec 3>>"%s"\nwhile :; do sleep 1 3>&-; done\n' "$REC/on_air.mp4" > "$ROOT/fakerec$$x/rec"
    bash "$ROOT/fakerec$$x/rec" & recpid=$!; sleep 1
}
stop_live() { kill "$recpid"; wait "$recpid" 2>/dev/null; }
LIVE7="$REC/Ready to upload/Salsabeel live 2026-11-07 18-02.mp4"
start_live; opened_before=$(opened); : > "$ROOT/test.log"
head -c 2500000 /dev/urandom > "$LIVE7"
rm -f "$ROOT/app/line-speeds" "$ROOT/app/line-learned"
trickle_setup 'LIVE_GUARD_EVERY=2'
agos "$ROOT/app/status-sent" 360
t0=$(date +%s)
bash "$ROOT/app/upload-lives.sh" & up=$!
seen_note=""; seen_page=""; seen_notice=""
for i in $(seq 1 40); do
    kill -0 "$up" 2>/dev/null || break
    grep -qE '^Now: +A live is on: uploading slowly \([0-9.]+ Mbit/s\), Salsabeel live 2026-11-07 18-02 [0-9]+%$' "$NOTE" 2>/dev/null && seen_note=1
    grep -q "Uploading slowly during the live" "$PAGE" 2>/dev/null && seen_page=1
    grep -q "Please leave the laptop open after the last live until uploads say Done" "$PAGE" 2>/dev/null && seen_notice=1
    sleep 1
done
wait "$up"; took=$(( $(date +%s) - t0 ))
check "a live on: it uploads anyway, from 1.5 Mbit/s (capped, $took seconds for 2.5 MB)" \
      '[ ! -e "$LIVE7" ] && [ -e "$DRIVE/Salsabeel live 2026-11-07 18-02.mp4" ] && [ "$took" -ge 6 ] && grep -q "uploading Salsabeel live 2026-11-07 18-02 at 1.5 Mbit/s, up to 4.0" "$ROOT/test.log"'
check "a live on: the note says \"A live is on: uploading slowly (… Mbit/s), Salsabeel live 2026-11-07 18-02 …%\", and so does the page" \
      '[ -n "$seen_note" ] && [ -n "$seen_page" ]'
check "the page asks them to leave the laptop open while lives wait, and not once they are all up" \
      '[ -n "$seen_notice" ] && ! grep -q "Please leave the laptop open" "$PAGE"'
check "a live on: the live recording itself is never touched, and the page never pops up" \
      '[ -e "$REC/on_air.mp4" ] && [ "$(fsize_of "$REC/on_air.mp4")" = 4096 ] && [ ! -e "$DRIVE/on_air.mp4" ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ] && [ "$(opened)" = "$opened_before" ]'

# The ceiling: the lowest of 20 Mbit/s, 40% of the line, and the line less 10; at least 1.5; 4 until the line is known
ceiling() { rm -f "$ROOT/app/line-learned"; if [ -n "$1" ]; then echo "$1" > "$ROOT/app/line-speeds"; else rm -f "$ROOT/app/line-speeds"; fi
            trickle_setup "$2"; bash "$ROOT/app/upload-lives.sh" --live-ceiling; }
c900=$(ceiling 900000); c40=$(ceiling 40000); c15=$(ceiling 15000); c0=$(ceiling ""); c5=$(ceiling 5000); c900nocap=$(ceiling 900000 'LIVE_UPLOAD_MAX_MBIT=""')
check "the ceiling: a 900 Mbit/s line gives 20, 40 gives 16, 15 gives 5, unknown 4, 5 gives 1.5, 900 with no hard cap 360 ($c900 $c40 $c15 $c0 $c5 $c900nocap)" \
      '[ "$c900 $c40 $c15 $c0 $c5 $c900nocap" = "20.0 16.0 5.0 4.0 1.5 360.0" ]'

# The ramp: 25% faster after each quiet spell (2 minutes; 1 second here), up to the ceiling
: > "$ROOT/test.log"; echo 20000 > "$ROOT/app/line-speeds"
head -c 20000000 /dev/urandom > "$LIVE7"
trickle_setup 'LIVE_RAMP_SECONDS=1
LIVE_GUARD_EVERY=1
LIVE_GUARD_FAST_EVERY=1'
bash "$ROOT/app/upload-lives.sh" & up=$!
for i in $(seq 1 90); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
steps=$(grep -c "Upload speed during the live: .* (fine for" "$ROOT/test.log")
check "the ramp: with the stream fine, it climbs 25% at a time from 1.5 to the ceiling (8 on a 20 Mbit/s line; $steps steps), never past it" \
      '! kill -0 "$up" 2>/dev/null && grep -q "Upload speed during the live: 8.0 Mbit/s (fine for" "$ROOT/test.log" && [ "$steps" = 8 ] && [ ! -e "$LIVE7" ]'
kill "$up" 2>/dev/null

# Fast back-off: one bad reading halves, two drop to 1.5, three pause; the baseline is only measured while nothing is sent
: > "$ROOT/test.log"; echo 20000 > "$ROOT/app/line-speeds"; rm -f "$ROOT/app/line-learned"
head -c 6000000 /dev/urandom > "$LIVE7"
printf '20 0\n20 0\n60 0\n20 0\n20 0\n75 0\n75 0\n20 3\n20 0\n' > "$ROOT/ping-seq"   # 60 = only 40 ms worse: still fine
trickle_setup 'LIVE_RAMP_SECONDS=1
LIVE_GUARD_EVERY=1
LIVE_GUARD_FAST_EVERY=1
LIVE_PAUSE_SECONDS=6
LIVE_RELAX_SECONDS=999'
bash "$ROOT/app/upload-lives.sh" & up=$!
seen_held=""
for i in $(seq 1 90); do
    kill -0 "$up" 2>/dev/null || break
    grep -q "Upload paused to protect the stream" "$PAGE" 2>/dev/null && seen_held=1
    sleep 1
done
wait "$up"
order=$(grep -oE "3\.7 Mbit/s \(fine|1\.8 Mbit/s \(halved|1\.5 Mbit/s \(back to the minimum|Upload stopped for|measured while not uploading|Carrying on with the upload at 1\.5" "$ROOT/test.log" | paste -sd '|' -)
check "back-off: one bad reading (55 ms worse) halves at once, the next drops to 1.5" \
      'grep -q "1.8 Mbit/s (halved: delay 75 ms against 20 ms" "$ROOT/test.log" && grep -q "1.5 Mbit/s (back to the minimum: delay 75 ms against 20 ms" "$ROOT/test.log"'
check "back-off: a third bad reading (pings lost) pauses, and the page says so" \
      'grep -q "Upload stopped for .* to protect the stream (delay 20 ms against 20 ms, 60% of pings lost)" "$ROOT/test.log" && [ -n "$seen_held" ]'
check "the baseline is measured only while nothing is sent: at the start and during the pause" \
      '[ "$order" = "measured while not uploading|3.7 Mbit/s (fine|1.8 Mbit/s (halved|1.5 Mbit/s (back to the minimum|Upload stopped for|measured while not uploading|Carrying on with the upload at 1.5" ] && [ ! -e "$LIVE7" ]'
rm -f "$ROOT/ping-seq"

# The line's speed, for Brandon: in the note and on the page
bash "$ROOT/app/upload-lives.sh" --status-now
check "the note says the line's speed: \"Line: 20 Mbit/s up (measured …, best of the last 1 reading)\", and so does the page" \
      'grep -qE "^Line: +20 Mbit/s up \(measured [0-9]{2}:[0-9]{2}, best of the last 1 reading\)$" "$NOTE" && grep -q "Line: 20 Mbit/s up" "$PAGE"'
rm -f "$ROOT/app/line-speeds"
bash "$ROOT/app/upload-lives.sh" --status-now
check "not measured yet: the note says so" 'grep -qE "^Line: +not measured yet$" "$NOTE"'

# A new version during a live upload: it is installed, but the upload is not started again
: > "$ROOT/test.log"; SITE="$ROOT/site-live"; mkdir -p "$SITE"; publish vL1; echo vL1 > "$ROOT/app/VERSION"
head -c 8000000 /dev/urandom > "$LIVE7"
trickle_setup "UPDATE_URL=file://$SITE
UPDATE_EVERY=20"
agos "$ROOT/app/update-checked" 100
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 5; publish vL2                                     # a new version appears while it uploads
for i in $(seq 1 120); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
check "a new version during a live upload: installed, but the slow upload carries on to the end" \
      '[ "$(cat "$ROOT/app/VERSION")" = vL2 ] && grep -q "takes over after this upload" "$ROOT/test.log" && ! grep -q "Updated mid-upload" "$ROOT/test.log" && [ ! -e "$LIVE7" ] && grep -q "Uploaded to" "$ROOT/test.log"'
kill "$up" 2>/dev/null; cp upload-lives.sh status-page.html "$ROOT/app/"

# A live starts mid-upload: it slows down without starting again; the live ends: full speed at once
: > "$ROOT/test.log"; stop_live; rm -f "$REC/on_air.mp4"
head -c 14000000 /dev/urandom > "$LIVE7"
trickle_setup 'BWLIMIT=400k'                              # "full speed" here, so there is time to watch
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 3; start_live
for i in $(seq 1 30); do kill -0 "$up" 2>/dev/null || break; grep -q "a live started" "$ROOT/test.log" && break; sleep 1; done
sleep 3; stop_live; ago "$REC/on_air.mp4" 10
for i in $(seq 1 60); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
check "a live starts mid-upload: it slows to 1.5 Mbit/s without starting the file again" \
      'grep -q "Upload speed during the live: 1.5 Mbit/s (a live started" "$ROOT/test.log" && ! grep -q "upload stopped" "$ROOT/test.log"'
check "it logs \"Live started (file …)\" and \"Live stopped\"" \
      'grep -q "Live started (file \"$REC/on_air.mp4\")" "$ROOT/test.log" && grep -q "Live stopped (" "$ROOT/test.log"'
check "the live ends: back to full speed at once, and the upload finishes" \
      '! kill -0 "$up" 2>/dev/null && grep -q "The live has ended: uploading at full speed." "$ROOT/test.log" && [ ! -e "$LIVE7" ] && grep -q "Uploaded to" "$ROOT/test.log"'
kill "$up" 2>/dev/null; rm -f "$REC/on_air.mp4"
setup "$DRIVE"

# Lives Brandon's PC has copied are deleted during a long live upload too (only API calls), and failures are logged
: > "$ROOT/test.log"; start_live
head -c 4000000 /dev/urandom > "$LIVE7"
trickle_setup 'CLEAR_EVERY=3'
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 4; head -c 4096 /dev/zero > "$DRIVE/Copied - Salsabeel live 2026-11-06 18-00.mp4"
for i in $(seq 1 20); do [ -e "$DRIVE/Copied - Salsabeel live 2026-11-06 18-00.mp4" ] || break; sleep 1; done
check "a copied live is deleted mid-upload during a live, not hours later" \
      'kill -0 "$up" 2>/dev/null && [ ! -e "$DRIVE/Copied - Salsabeel live 2026-11-06 18-00.mp4" ] && grep -q "Deleted \"Copied - Salsabeel live 2026-11-06 18-00.mp4\"" "$ROOT/test.log"'
wait "$up"; stop_live; rm -f "$REC/on_air.mp4"
cat > "$ROOT/nodelete-rclone" <<EOF
#!/bin/bash
if [ "\$1" = deletefile ]; then echo "ERROR : googleapi: Error 403: The user does not have sufficient permissions for this file., insufficientFilePermissions" >&2; exit 1; fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/nodelete-rclone"
head -c 4096 /dev/zero > "$DRIVE/Copied - Salsabeel live 2026-11-05 18-00.mp4"; : > "$ROOT/test.log"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nCLEAR_EVERY=0\n' "$REC" "$DRIVE" "$ROOT/nodelete-rclone" > "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh"; bash "$ROOT/app/upload-lives.sh"
check "a delete that fails is logged with Google's reason, once (not every minute)" \
      '[ "$(grep -c "Could not delete \"Copied - Salsabeel live 2026-11-05 18-00.mp4\" from Google Drive: .*insufficientFilePermissions" "$ROOT/test.log")" = 1 ]'
setup "$DRIVE"; rm -f "$DRIVE/Copied - Salsabeel live 2026-11-05 18-00.mp4"

# Drive full: the copied lives are deleted first, every minute, before the Drive check
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nDRIVE_MARGIN_MB=0\n' "$REC" "testdrive:Salsabeel lives" "$ROOT/small-rclone" > "$ROOT/app/config.sh"
printf '[testdrive]\ntype = alias\nremote = %s\n' "$ROOT/Google Drive" > "$ROOT/rclone.conf"
echo 100 > "$ROOT/drive-free"; : > "$ROOT/test.log"; touch "$ROOT/app/cleared-checked"; echo full > "$ROOT/app/full-noted"
head -c 4096 /dev/zero > "$REC/Ready to upload/Salsabeel live 2026-11-09 18-02.mp4"
head -c 4096 /dev/zero > "$DRIVE/Copied - Salsabeel live 2026-11-04 18-00.mp4"
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
order=$(grep -oE "Deleted \"Copied - Salsabeel live 2026-11-04|Google Drive is full" "$ROOT/test.log" | paste -sd '|' -)
check "Drive full: copied lives are deleted every minute, before the Drive check ($order)" \
      '[ "$order" = "Deleted \"Copied - Salsabeel live 2026-11-04|Google Drive is full" ]'
setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

# The bin (Brandon, 12 Nov: "only the live stream files"): live recordings in this app's bin go for good; nothing else
BIN="$ROOT/bin-drive"; rm -rf "$BIN"; mkdir -p "$BIN/Salsabeel lives/Uploader checks/Short recordings"
head -c 2097152 /dev/zero > "$BIN/Salsabeel lives/Salsabeel live 2026-11-01 18-00.mp4"
head -c 4096 /dev/zero > "$BIN/Salsabeel lives/Copied - Salsabeel live 2026-11-02 18-00.mp4"
echo note > "$BIN/Salsabeel lives/Uploader checks/Mac status.txt"
echo report > "$BIN/Salsabeel lives/Uploader checks/Fix report 2026-11-03 10-00.txt"
head -c 4096 /dev/zero > "$BIN/Salsabeel lives/Uploader checks/Short recordings/Short recording 2026-11-03 10-00.mp4"
head -c 4096 /dev/zero > "$BIN/Salsabeel lives/Uploader checks/Salsabeel live test.mp4"
head -c 4096 /dev/zero > "$BIN/Salsabeel lives/holiday.mp4"
cat > "$ROOT/bin-rclone" <<EOF
#!/bin/bash
# Pretend Google Drive: this remote is "drive", and --drive-trashed-only sees the pretend bin.
if [ "\$1 \${2:-}" = "listremotes --long" ]; then echo "testdrive:           drive"; exit 0; fi
case " \$* " in *" --drive-trashed-only "*)
    if [ "\$1" = lsf ]; then (cd "$BIN" && find . -type f | sed 's#^\./##' | while IFS= read -r f; do echo "\$(wc -c < "\$f" | tr -d ' ');\$f"; done); exit 0; fi
    if [ "\$1" = deletefile ]; then rm -f "$BIN/\${2#testdrive:}"; exit 0; fi
    exit 1 ;;
esac
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/bin-rclone"
printf '[testdrive]\ntype = alias\nremote = %s\n' "$ROOT/Google Drive" > "$ROOT/rclone.conf"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "testdrive:Salsabeel lives" "$ROOT/bin-rclone" > "$ROOT/app/config.sh"
: > "$ROOT/test.log"; rm -f "$ROOT/app/bin-checked"
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
check "the bin: this app's live recordings in it are deleted for good, and logged with their size" \
      '[ ! -e "$BIN/Salsabeel lives/Salsabeel live 2026-11-01 18-00.mp4" ] && [ ! -e "$BIN/Salsabeel lives/Copied - Salsabeel live 2026-11-02 18-00.mp4" ] &&
       grep -q "Emptied from the Google Drive bin for good: \"Salsabeel lives/Salsabeel live 2026-11-01 18-00.mp4\" (2 MB)" "$ROOT/test.log"'
check "the bin: the status note, fix reports, short and test recordings, and other videos are never touched" \
      '[ -e "$BIN/Salsabeel lives/Uploader checks/Mac status.txt" ] && [ -e "$BIN/Salsabeel lives/Uploader checks/Fix report 2026-11-03 10-00.txt" ] &&
       [ -e "$BIN/Salsabeel lives/Uploader checks/Short recordings/Short recording 2026-11-03 10-00.mp4" ] &&
       [ -e "$BIN/Salsabeel lives/Uploader checks/Salsabeel live test.mp4" ] && [ -e "$BIN/Salsabeel lives/holiday.mp4" ]'
head -c 4096 /dev/zero > "$BIN/Salsabeel lives/Salsabeel live 2026-11-04 18-00.mp4"
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
check "the bin: once an hour, not every minute" '[ -e "$BIN/Salsabeel lives/Salsabeel live 2026-11-04 18-00.mp4" ]'
printf '[testdrive]\ntype = alias\nremote = %s\n' "$ROOT/Google Drive" > "$ROOT/rclone.conf"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nDRIVE_MARGIN_MB=0\n' "$REC" "testdrive:Salsabeel lives" "$ROOT/bin-rclone" > "$ROOT/app/config.sh"
printf '#!/bin/bash\nif [ "$1" = about ]; then echo "{\\"total\\":15000,\\"free\\":100}"; exit 0; fi\nexec %q "$@"\n' "$ROOT/bin-rclone" > "$ROOT/full-bin-rclone"; chmod +x "$ROOT/full-bin-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nDRIVE_MARGIN_MB=0\n' "$REC" "testdrive:Salsabeel lives" "$ROOT/full-bin-rclone" > "$ROOT/app/config.sh"
head -c 4096 /dev/zero > "$REC/Ready to upload/Salsabeel live 2026-11-09 19-02.mp4"
RCLONE_CONFIG="$ROOT/rclone.conf" bash "$ROOT/app/upload-lives.sh"
check "the bin: straight after Drive reads full, without waiting the hour" '[ ! -e "$BIN/Salsabeel lives/Salsabeel live 2026-11-04 18-00.mp4" ] && grep -q "Google Drive is full" "$ROOT/test.log"'
setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

# The line's speed: the best of the last 5 readings (one slow reading must not drag the live ceiling to 1.5)
rm -f "$ROOT/app/line-learned"; printf '60000\n7400\n' > "$ROOT/app/line-speeds"; trickle_setup ''
best=$(bash "$ROOT/app/upload-lives.sh" --live-ceiling)
check "the line's speed is the best recent reading: 60 and 7.4 give a live ceiling of 20 ($best)" '[ "$best" = 20.0 ]'
# ... read from time at full speed, with sane bounds
rm -f "$ROOT/app/line-speeds"; : > "$ROOT/test.log"
head -c 3000000 /dev/urandom > "$REC/Ready to upload/Salsabeel live 2026-11-12 10-02.mp4"
trickle_setup 'BWLIMIT=500k
LINE_SAMPLE_MIN_MB=1
LINE_SAMPLE_MIN_SECONDS=3'
bash "$ROOT/app/upload-lives.sh"
got=$(tail -n 1 "$ROOT/app/line-speeds" 2>/dev/null)
check "a full-speed upload gives a line reading (about 4 Mbit/s at a 500 KiB/s cap: ${got:-none} kbit/s)" \
      '[ -n "$got" ] && [ "$got" -ge 2500 ] && [ "$got" -le 6000 ] && grep -q "The line.s upload speed was" "$ROOT/test.log"'
echo 999 >> "$ROOT/app/line-speeds"; rm -f "$ROOT/app/line-speeds"

# A long upload keeps "last-run" fresh (launchd starts no other run meanwhile), so it is not taken for a sleep;
# a real stall mid-upload is
: > "$ROOT/test.log"; echo 0 > "$ROOT/app/waiting-count"
head -c 7000000 /dev/urandom > "$REC/Ready to upload/Salsabeel live 2026-11-12 16-02.mp4"
trickle_setup 'BWLIMIT=200k
SLEEP_GAP_SECONDS=5'
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 7; fresh=$(( $(date +%s) - $(mtime_of "$ROOT/app/last-run") ))
kill -STOP "$up"; sleep 8; kill -CONT "$up"           # the Mac "sleeps" mid-upload
for i in $(seq 1 150); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
slept=$(grep -c "Asleep: the Mac slept from" "$ROOT/test.log")
check "a long upload keeps last-run fresh ($fresh s old after 7 s), so it is not taken for a sleep" '[ "$fresh" -le 3 ]'
check "a real stall mid-upload is logged as a sleep, once ($slept), with the lives waiting" \
      '[ "$slept" = 1 ] && grep -qE "Asleep: the Mac slept from .* with [0-9]+ lives? waiting" "$ROOT/test.log"'
check "after the stall, the same upload carries on and finishes" \
      '! kill -0 "$up" 2>/dev/null && [ ! -e "$REC/Ready to upload/Salsabeel live 2026-11-12 16-02.mp4" ]'
rm -f "$ROOT/app/last-sleep"; setup "$DRIVE"

# Uploading in parts (PARTS_UPLOAD=on; off by default): Parts/<name>/part-0001 ..., the manifest last
md5of() { if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
check "parts are off by default: lives go up whole" '[ ! -d "$DRIVE/Parts" ]'
P1="Salsabeel live 2026-11-13 10-02.mp4"; PD1="$DRIVE/Parts/$P1"
head -c 3670016 /dev/urandom > "$REC/Ready to upload/$P1"; want=$(md5of "$REC/Ready to upload/$P1")
setup "$DRIVE" 'PARTS_UPLOAD=on
PART_MB=1
PART_LIVE_MB=1
PARTS_MIN_MB=1'
: > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"
joined=$(cat "$PD1"/part-000[1-4] 2>/dev/null | { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi; })
check "in parts: 4 parts of 1 MiB (the last 0.5), and the manifest last, with each part's size and md5" \
      '[ "$(ls "$PD1" | grep -c "^part-")" = 4 ] && grep -qx "clipline-parts 1" "$PD1/manifest.txt" && grep -qx "name: $P1" "$PD1/manifest.txt" &&
       grep -qx "size: 3670016" "$PD1/manifest.txt" && grep -qx "md5: $want" "$PD1/manifest.txt" &&
       grep -qx "part: part-0004 524288 $(md5of "$PD1/part-0004")" "$PD1/manifest.txt" && [ "$joined" = "$want" ]'
check "in parts: nothing goes up whole, and the recording waits in .sent until the cloud has joined it" \
      '[ ! -e "$DRIVE/$P1" ] && [ ! -e "$REC/Ready to upload/$P1" ] && [ -e "$REC/.sent/$P1" ] && grep -q "All 4 parts" "$ROOT/test.log"'
# Stopped mid-way (part 3 fails once), and part 2 spoilt in Drive meanwhile: it carries on from part 2, never part 1
P2="Salsabeel live 2026-11-13 16-02.mp4"; PD2="$DRIVE/Parts/$P2"
head -c 4194304 /dev/urandom > "$REC/Ready to upload/$P2"; want2=$(md5of "$REC/Ready to upload/$P2")
cat > "$ROOT/parts-rclone" <<EOF
#!/bin/bash
if [ "\$1" = rcat ]; then
    echo "\${2##*/}" >> "$ROOT/rcat-calls"
    if [ "\${2##*/}" = part-0003 ] && [ ! -e "$ROOT/failed-once" ]; then touch "$ROOT/failed-once"; cat > /dev/null; exit 1; fi
fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/parts-rclone"; rm -f "$ROOT/rcat-calls" "$ROOT/failed-once"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nPARTS_UPLOAD=on\nPART_MB=1\nPART_LIVE_MB=1\nPARTS_MIN_MB=1\n' "$REC" "$DRIVE" "$ROOT/parts-rclone" > "$ROOT/app/config.sh"
: > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"
check "a stop mid-way: the parts already sent stay, and the recording waits" \
      '[ -e "$PD2/part-0001" ] && [ -e "$PD2/part-0002" ] && [ ! -e "$PD2/manifest.txt" ] && [ -e "$REC/Ready to upload/$P2" ]'
head -c 1048576 /dev/zero > "$PD2/part-0002"   # spoilt in Drive
bash "$ROOT/app/upload-lives.sh"
check "the next run carries on: a spoilt part goes again, part 1 never does, and the whole file checks out" \
      '[ "$(grep -cx part-0001 "$ROOT/rcat-calls")" = 1 ] && [ "$(grep -cx part-0002 "$ROOT/rcat-calls")" = 2 ] &&
       grep -q "part-0002 of \"$P2\" is not in Drive as sent" "$ROOT/test.log" && grep -qx "md5: $want2" "$PD2/manifest.txt" &&
       [ "$(cat "$PD2"/part-000[1-4] | { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d" " -f1; fi; })" = "$want2" ]'
# The cloud has joined it ("Parts/Copied - <name>"): the folder and the copy here go
mv "$PD1" "$DRIVE/Parts/Copied - $P1"; rm -f "$ROOT/app/cleared-checked"
setup "$DRIVE" 'PARTS_UPLOAD=on'; bash "$ROOT/app/upload-lives.sh"
check "once the cloud has joined it (Copied - …), its parts folder and the copy here are deleted, and nothing else" \
      '[ ! -e "$DRIVE/Parts/Copied - $P1" ] && [ ! -e "$REC/.sent/$P1" ] && [ -e "$REC/.sent/$P2" ] && [ -e "$PD2/manifest.txt" ]'
# During a live: the smaller part size, at the live speed (1.5 Mbit/s to start)
P3="Salsabeel live 2026-11-13 19-02.mp4"; PD3="$DRIVE/Parts/$P3"; start_live
head -c 3145728 /dev/urandom > "$REC/Ready to upload/$P3"
trickle_setup 'PARTS_UPLOAD=on
PART_MB=2
PART_LIVE_MB=1
PARTS_MIN_MB=1'
t0=$(date +%s); : > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"; took=$(( $(date +%s) - t0 ))
stop_live; rm -f "$REC/on_air.mp4"
check "during a live, parts are the live size (3 × 1 MiB) and go at the live speed ($took s for 3 MiB)" \
      '[ "$(ls "$PD3" | grep -c "^part-")" = 3 ] && [ -e "$PD3/manifest.txt" ] && [ "$took" -ge 10 ] && grep -q "A live is on: uploading" "$ROOT/test.log"'
rm -rf "$DRIVE/Parts" "$REC/.sent"; setup "$DRIVE"

# A line reading every 10 minutes (4 seconds here) at full speed, so a long upload cut short still gives one
rm -f "$ROOT/app/line-speeds"; : > "$ROOT/test.log"
head -c 6000000 /dev/urandom > "$REC/Ready to upload/Salsabeel live 2026-11-14 10-02.mp4"
trickle_setup 'BWLIMIT=400k
LINE_SAMPLE_EVERY=4
LINE_SAMPLE_MIN_MB=1
LINE_SAMPLE_MIN_SECONDS=3'
bash "$ROOT/app/upload-lives.sh"
readings=$(grep -c . "$ROOT/app/line-speeds" 2>/dev/null || echo 0)
check "a long full-speed upload gives a line reading every few minutes, not only at the end ($readings)" '[ "$readings" -ge 2 ]'
rm -f "$ROOT/app/line-speeds"

# A live ends with uploads left: one friendly note on screen to keep the laptop open (never during the live)
printf '#!/bin/bash\necho "$1" >> "%s"\n' "$ROOT/notes-shown" > "$ROOT/fake-notify"; chmod +x "$ROOT/fake-notify"; rm -f "$ROOT/notes-shown"
head -c 4096 /dev/zero > "$REC/Ready to upload/Salsabeel live 2026-11-14 16-02.mp4"
start_live; setup "$DRIVE" 'LIVE_UPLOAD=off'
SALSABEEL_UPLOADER_NOTIFY="$ROOT/fake-notify" bash "$ROOT/app/upload-lives.sh"
during=$(cat "$ROOT/notes-shown" 2>/dev/null)
stop_live; rm -f "$REC/on_air.mp4"
SALSABEEL_UPLOADER_NOTIFY="$ROOT/fake-notify" bash "$ROOT/app/upload-lives.sh"
check "a live ends with uploads left: \"Uploading: about N minutes left. Please keep the laptop open.\" once, and nothing during the live" \
      '[ -z "$during" ] && [ "$(grep -c "^Uploading: about [0-9]* minutes\? left. Please keep the laptop open.$" "$ROOT/notes-shown")" = 1 ]'
rm -f "$ROOT/app/paused"; setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

# Paused for a live (its speed can't be changed): the page says paused, never "uploading slowly ( Mbit/s)"; the log says why
: > "$ROOT/test.log"; head -c 6000000 /dev/urandom > "$REC/Ready to upload/Salsabeel live 2026-11-15 10-02.mp4"
cat > "$ROOT/norc-rclone" <<EOF
#!/bin/bash
# As on the Mac on 15 Nov: the transfer works, but its remote control does not answer
if [ "\$1" = rc ]; then echo "Failed to rc: connection failed: dial tcp 127.0.0.1:5590: connect: connection refused" >&2; exit 1; fi
exec "$ROOT/trickle-rclone" "\$@"
EOF
chmod +x "$ROOT/norc-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\nBWLIMIT=300k\n' "$REC" "$DRIVE" "$ROOT/norc-rclone" > "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 4; start_live
for i in $(seq 1 30); do grep -q "upload is paused until it ends" "$ROOT/test.log" && break; sleep 1; done
sleep 5; slowpage=$(grep -c "Uploading slowly" "$PAGE"); pausedpage=$(grep -c "Paused" "$PAGE")
stop_live; mv "$REC/on_air.mp4" "$ROOT/on_air_done.mp4"
for i in $(seq 1 90); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
check "paused for a live: the page says paused, not \"uploading slowly\" with no speed" '[ "$slowpage" = 0 ] && [ "$pausedpage" -ge 1 ]'
check "when rclone's remote control does not answer, the log says why (once)" \
      '[ "$(grep -c "Could not change rclone.s speed (at http://127.0.0.1:[0-9]*/.*connection refused" "$ROOT/test.log")" = 1 ]'
rm -f "$ROOT/on_air_done.mp4" "$ROOT/app/paused"; setup "$DRIVE"

# Its remote control does not answer (as on the Mac, 15–17 Nov): the speed limit is toggled by signal instead (SIGUSR2),
# so the upload goes on at the live ceiling during a live, not paused, and at full speed again after it
cat > "$ROOT/usr2-rclone" <<EOF
#!/bin/bash
# A pretend rclone: its remote control never answers; SIGUSR2 toggles its limit (noted); the move takes 50 s
if [ "\$1" = rc ]; then echo "Failed to rc: connection failed: connect: connection refused" >&2; exit 1; fi
if [ "\$1" = move ]; then
    trap 'echo usr2 >> "$ROOT/usr2-calls"' USR2
    for a in "\$@"; do [ -n "\${next:-}" ] && log="\$a"; next=; [ "\$a" = --log-file ] && next=1; done
    for i in \$(seq 1 50); do echo "2026/11/17 16:00:00 NOTICE:    \$i MiB / 50 MiB, \$(( i * 2 ))%, 1.000 MiB/s, ETA 1s" >> "\$log"; sleep 1; done
    exec "$RCLONE" "\$@"
fi
exec "$RCLONE" "\$@"
EOF
chmod +x "$ROOT/usr2-rclone"; rm -f "$ROOT/usr2-calls"; : > "$ROOT/test.log"
echo 90000 > "$ROOT/app/line-speeds"   # a 90 Mbit/s line: a live ceiling of 20
head -c 4096 /dev/zero > "$REC/Ready to upload/Salsabeel live 2026-11-17 10-02.mp4"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$DRIVE" "$ROOT/usr2-rclone" > "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 6; start_live
for i in $(seq 1 40); do grep -q "set by signal" "$ROOT/test.log" && break; sleep 1; done
sleep 3; during=$(grep -c . "$ROOT/usr2-calls" 2>/dev/null)
stop_live; mv "$REC/on_air.mp4" "$ROOT/on_air_done.mp4"
for i in $(seq 1 120); do kill -0 "$up" 2>/dev/null || break; sleep 1; done
after=$(grep -c . "$ROOT/usr2-calls" 2>/dev/null)
check "no remote control: full speed by signal once it runs, then the live ceiling by signal when a live starts (not paused)" \
      '[ "$during" = 2 ] && grep -q "Upload speed during the live: 20.0 Mbit/s (set by signal" "$ROOT/test.log" && ! grep -q "paused until it ends" "$ROOT/test.log"'
check "no remote control: back to full speed by signal when the live ends, and the upload finishes" \
      '[ "$after" = 3 ] && grep -q "The live has ended: uploading at full speed" "$ROOT/test.log" && [ ! -e "$REC/Ready to upload/Salsabeel live 2026-11-17 10-02.mp4" ]'
rm -f "$ROOT/on_air_done.mp4" "$ROOT/app/line-speeds"; setup "$DRIVE"

# The lid shut with lives waiting: the note says the Mac slept, and when
setup "$DRIVE"; echo 12 > "$ROOT/app/waiting-count"; agos "$ROOT/app/last-run" 39600; rm -f "$ROOT/app/status-sent" "$ROOT/app/last-sleep"
bash "$ROOT/app/upload-lives.sh"
check "the Mac slept with 12 lives waiting: logged, and in the note (\"Asleep: the Mac slept from … to … with 12 lives waiting\")" \
      'grep -q "Asleep: the Mac slept from .* with 12 lives waiting" "$ROOT/test.log" && grep -qE "^Asleep: +the Mac slept from [0-9]{2}:[0-9]{2} to [0-9]{2}:[0-9]{2} with 12 lives waiting$" "$NOTE"'
echo 0 > "$ROOT/app/waiting-count"; agos "$ROOT/app/last-run" 39600; rm -f "$ROOT/app/last-sleep"
bash "$ROOT/app/upload-lives.sh"
check "asleep with nothing waiting: nothing to say" '[ ! -e "$ROOT/app/last-sleep" ]'

# The morning: switched on with lives waiting and every check due, the first upload starts at once (and keeps the Mac awake)
mkdir -p "$ROOT/bin"; printf '#!/bin/bash\necho "$*" >> "%s"\n' "$ROOT/caffeinated" > "$ROOT/bin/caffeinate"; chmod +x "$ROOT/bin/caffeinate"
SITE="$ROOT/site-am"; mkdir -p "$SITE"; publish vAM; echo vAM > "$ROOT/app/VERSION"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=%q\n' "$REC" "$DRIVE" "$ROOT/trickle-rclone" "file://$SITE" > "$ROOT/app/config.sh"
for f in update-checked moved-checked cleared-checked last-run; do agos "$ROOT/app/$f" 39600; done
echo 3 > "$ROOT/app/waiting-count"; : > "$ROOT/test.log"
head -c 4096 /dev/zero > "$REC/Ready to upload/Salsabeel live 2026-11-10 18-02.mp4"
t0=$(date +%s)
PATH="$ROOT/bin:$PATH" bash "$ROOT/app/upload-lives.sh" & up=$!
for i in $(seq 1 60); do grep -q "Uploading Salsabeel live 2026-11-10 18-02.mp4" "$ROOT/test.log" && break; sleep 1; done
started=$(( $(date +%s) - t0 )); wait "$up"
check "the morning: the first upload starts within seconds of waking, after the hourly checks ($started s)" \
      '[ "$started" -le 20 ] && grep -q "Uploaded to" "$ROOT/test.log" && [ "$(cat "$ROOT/app/VERSION")" = vAM ]'
check "the morning: it keeps the Mac awake while it uploads (caffeinate)" 'grep -qE "^-ims -w [0-9]+$" "$ROOT/caffeinated"'
setup "$DRIVE"

# "Who are you?" at the start of a live: names from "Uploader checks/Presenters.txt" in Drive, the answer next to the live
# (pretend names here: real ones live only in Drive)
CHK="$DRIVE/Uploader checks"; mkdir -p "$CHK"; rm -f "$CHK/Presenters.txt" "$ROOT/app/presenters.txt" "$ROOT/app/presenters-checked"
setup "$DRIVE"; : > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"
check "no names list in Drive: it makes \"Presenters.txt\" (no names in it) for the cloud to fill" \
      '[ -f "$CHK/Presenters.txt" ] && ! grep -v "^#" "$CHK/Presenters.txt" | grep -q . && grep -q "Made \"Uploader checks/Presenters.txt\"" "$ROOT/test.log"'
cat > "$ROOT/fake-ask" <<EOF
#!/bin/bash
# A pretend "Who are you?" window: notes what it was shown, and clicks the second name
echo "\$*" >> "$ROOT/asked"
if [ -n "\${ASK_SLOW:-}" ]; then echo \$\$ > "$ROOT/ask-pid"; sleep 60; fi
echo "\$2"
EOF
chmod +x "$ROOT/fake-ask"; rm -f "$ROOT/asked"
export SALSABEEL_UPLOADER_ASK="$ROOT/fake-ask"
start_live; ago "$ROOT/app/presenters-checked" 20; bash "$ROOT/app/upload-lives.sh"
check "a live starts with no names in the list: nothing is asked" '[ ! -e "$ROOT/asked" ]'
stop_live; rm -f "$REC/on_air.mp4"; bash "$ROOT/app/upload-lives.sh"
printf '# Presenters\r\nAlice\r\n Bea \r\n\r\nCara\r\n' > "$CHK/Presenters.txt"; ago "$ROOT/app/presenters-checked" 20
start_live; : > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"
for i in $(seq 1 10); do ls "$ROOT/app/presenters/"*.names >/dev/null 2>&1 && break; sleep 1; done
bash "$ROOT/app/upload-lives.sh"
check "a live starts: \"Who are you?\" shows the names from Drive, once" \
      '[ "$(cat "$ROOT/asked")" = "Alice Bea Cara" ] && grep -q "Asked \"Who are you?\"" "$ROOT/test.log"'
check "the answer is kept on the Mac until the recording has its name" \
      '[ "$(cat "$ROOT/app/presenters/"*.names)" = Bea ] && grep -q "on this live: Bea (clicked)" "$ROOT/test.log"'
check "the note says the live is on, and who clicked, at once (for the live screen)" \
      'grep -qE "^Live: +on since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$" "$NOTE" && grep -qx "Presenters:         Bea" "$NOTE" && [ ! -e "$ROOT/app/status-due" ]'
stop_live; ago "$REC/on_air.mp4" 10; : > "$ROOT/test.log"; bash "$ROOT/app/upload-lives.sh"
check "the live stops: the note says \"Live: off\" (and no presenters line)" \
      'grep -qx "Live:               off" "$NOTE" && ! grep -q "^Presenters:" "$NOTE"'
VID=$(cd "$DRIVE" && ls Salsabeel\ live\ *.mp4 2>/dev/null | while IFS= read -r v; do [ -f "$v.presenters.txt" ] && echo "$v"; done | head -n 1)
check "once the live has stopped: \"<recording>.presenters.txt\" goes next to it in Drive, with the name clicked" \
      '[ -n "$VID" ] && [ "$(cat "$DRIVE/$VID.presenters.txt")" = Bea ] && [ -z "$(ls "$ROOT/app/presenters/")" ]'
if [ -n "$VID" ]; then mv "$DRIVE/$VID" "$DRIVE/Copied - $VID"; fi; rm -f "$ROOT/app/cleared-checked"; bash "$ROOT/app/upload-lives.sh"
check "the cloud takes the live (\"Copied - …\"): its presenters file is deleted with it" \
      '[ -n "$VID" ] && [ ! -e "$DRIVE/Copied - $VID" ] && [ ! -e "$DRIVE/$VID.presenters.txt" ]'
rm -f "$ROOT/asked"; start_live; : > "$ROOT/test.log"
ASK_SLOW=1 SALSABEEL_UPLOADER_ASK_WAIT=3 bash "$ROOT/app/upload-lives.sh"
for i in $(seq 1 15); do grep -q "closed by itself" "$ROOT/test.log" && break; sleep 1; done
check "nobody answers: it closes by itself (the list is shut), and nothing is saved" \
      'grep -q "Nobody answered" "$ROOT/test.log" && ! kill -0 "$(cat "$ROOT/ask-pid")" 2>/dev/null && ! ls "$ROOT/app/presenters/"*.names >/dev/null 2>&1'
stop_live; ago "$REC/on_air.mp4" 10; bash "$ROOT/app/upload-lives.sh"
check "no answer: no presenters file in Drive (the website tap-in covers it)" 'grep -q "  Uploaded to" "$ROOT/test.log" && [ "$(count "$DRIVE" "*.presenters.txt")" = 0 ]'
rm -f "$ROOT/app/presenters/"*; printf '#!/bin/bash\nexit 1\n' > "$ROOT/no-window"; chmod +x "$ROOT/no-window"
printf '#!/bin/bash\necho "$3"\n' > "$ROOT/fake-list"; chmod +x "$ROOT/fake-list"
start_live; : > "$ROOT/test.log"
printf '#!/bin/bash\necho "$1" >> "%s"\n' "$ROOT/thanked" > "$ROOT/fake-thanks"; chmod +x "$ROOT/fake-thanks"; rm -f "$ROOT/thanked"
export SALSABEEL_UPLOADER_THANKS="$ROOT/fake-thanks"
SALSABEEL_UPLOADER_ASK="$ROOT/no-window" SALSABEEL_UPLOADER_ASK2="$ROOT/fake-list" bash "$ROOT/app/upload-lives.sh"
for i in $(seq 1 10); do [ -s "$ROOT/thanked" ] && break; sleep 1; done
check "the window won't open: it asks with a plain list instead, then says thanks to that name" \
      'grep -q "would not open (error 1)" "$ROOT/test.log" && [ "$(cat "$ROOT/app/presenters/"*.names)" = Cara ] && [ "$(cat "$ROOT/thanked")" = Cara ]'
stop_live; ago "$REC/on_air.mp4" 10; bash "$ROOT/app/upload-lives.sh"
# The window's thank-you goes wrong after the click: the name is kept, and the list never comes back
rm -rf "$ROOT/app/presenters"; rm -f "$ROOT/thanked" "$ROOT/listed"
printf '#!/bin/bash\necho "$2"\nexit 1\n' > "$ROOT/thanks-fails"; chmod +x "$ROOT/thanks-fails"
printf '#!/bin/bash\necho listed >> "%s"\necho "$1"\n' "$ROOT/listed" > "$ROOT/count-list"; chmod +x "$ROOT/count-list"
start_live; : > "$ROOT/test.log"
SALSABEEL_UPLOADER_ASK="$ROOT/thanks-fails" SALSABEEL_UPLOADER_ASK2="$ROOT/count-list" bash "$ROOT/app/upload-lives.sh"
for i in $(seq 1 10); do grep -q "(clicked)" "$ROOT/test.log" && break; sleep 1; done; sleep 2
check "the thank-you fails after the click: the name is kept, and no second ask" \
      '[ "$(cat "$ROOT/app/presenters/"*.names)" = Bea ] && [ ! -e "$ROOT/listed" ] && ! grep -q "would not open" "$ROOT/test.log"'
stop_live; ago "$REC/on_air.mp4" 10; bash "$ROOT/app/upload-lives.sh"
rm -rf "$ROOT/app/presenters"
printf '#!/bin/bash\necho "$3"\necho $$ > "%s"\nsleep 60\n' "$ROOT/hang-pid" > "$ROOT/thanks-hangs"; chmod +x "$ROOT/thanks-hangs"
start_live; : > "$ROOT/test.log"
SALSABEEL_UPLOADER_ASK="$ROOT/thanks-hangs" SALSABEEL_UPLOADER_ASK2="$ROOT/count-list" SALSABEEL_UPLOADER_THANKS_MAX=3 bash "$ROOT/app/upload-lives.sh"
for i in $(seq 1 5); do grep -q "(clicked)" "$ROOT/test.log" && break; sleep 1; done
saved_fast=$(cat "$ROOT/app/presenters/"*.names 2>/dev/null)
sleep 5
check "the thank-you hangs: the name is saved at once, the window is shut soon after, and no second ask" \
      '[ "$saved_fast" = Cara ] && ! kill -0 "$(cat "$ROOT/hang-pid")" 2>/dev/null && [ ! -e "$ROOT/listed" ] && ! grep -q "Nobody answered" "$ROOT/test.log"'
stop_live; ago "$REC/on_air.mp4" 10; bash "$ROOT/app/upload-lives.sh"
unset SALSABEEL_UPLOADER_THANKS
# The window's page: the status page's look, a tile per name (a pretend osascript: no window opens here)
mkdir -p "$ROOT/who-bin"; printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\n' "$ROOT/osa-args" > "$ROOT/who-bin/osascript"; chmod +x "$ROOT/who-bin/osascript"
PATH="$ROOT/who-bin:$PATH" bash "$ROOT/app/upload-lives.sh" --who Alice 'B<e>a' Cara Dana Evie
check "the window's page: the uploader's look (logo, CLOCK IN), a tile per name (names made safe), and 2 columns for 5 names" \
      'W="$ROOT/app/who.html"; [ "$(grep -c "class=\"tile\"" "$W")" = 5 ] && grep -q "data:image/png;base64" "$W" && grep -q "<span>CLOCK IN</span>" "$W" &&
       grep -q "B&lt;e&gt;a" "$W" && grep -q "repeat(2, 1fr)" "$W" && grep -q "Thanks for clocking in" "$W" && sed -n 1p "$ROOT/osa-args" | grep -qx -- -l &&
       grep -qx "$ROOT/app/who.html" "$ROOT/osa-args" && grep -qx 600 "$ROOT/osa-args"'
unset SALSABEEL_UPLOADER_ASK; rm -rf "$ROOT/app/presenters" "$ROOT/app/presenters.txt"; setup "$DRIVE"

if [ -f manifest.txt ]; then
    check "manifest.txt matches these files (run streaming-mac/build.sh after a change)" \
          '( for n in upload-lives.sh status-page.html; do grep -qx "$(sha "$n")  $n" manifest.txt || exit 1; done )'
fi

echo
if [ "$fails" -eq 0 ]; then echo "SELF-TEST PASSED"; else echo "SELF-TEST FAILED ($fails)"; echo; cat "$ROOT/test.log"; exit 1; fi
