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
export SALSABEEL_UPLOADER_TEST=1                  # it may follow recordings in temporary folders (where this test works)
mkdir -p "$HOME"
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
RCLONE_CONFIG="$ROOT/offline.conf" bash ./upload-lives.sh 2>/dev/null
check "when the upload fails, the recordings wait in \"Ready to upload\"" \
      '[ "$(count "$REC/Ready to upload" "Salsabeel live *.mp4")" = 2 ]'
check "the page says it is waiting, tells them to leave the Mac on, and keeps refreshing" \
      'grep -q "Waiting for the internet" "$PAGE" && grep -q "leave the Mac on" "$PAGE" && grep -q "http-equiv=\"refresh\"" "$PAGE"'
setup "$DRIVE"
bash ./upload-lives.sh
check "the next try uploads them, two recordings never share a name" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = 3 ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ]'
check "a retry does not pop the page up again (it is already open)" '[ "$(opened)" = 2 ]'
echo stale > "$ROOT/app/page-opened-boot"; head -c 4096 /dev/zero > "$REC/Ready to upload/after-restart.mp4"
bash ./upload-lives.sh
check "after a restart mid-upload, the page pops up again" '[ "$(opened)" = 3 ]'

check "a status note for Brandon is in Google Drive, with the end of the log" \
      'grep -q "Waiting to upload:  0" "$DRIVE/Uploader checks/Mac status.txt" && grep -q "Uploading" "$DRIVE/Uploader checks/Mac status.txt"'

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
check "it is checked for once an hour, not every minute" \
      '[ -f "$ROOT/app/update-checked" ] && publish v2 && bash "$ROOT/app/upload-lives.sh" && [ "$(cat "$ROOT/app/VERSION")" = v1 ]'
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
sleep 1; head -c 4096 /dev/zero >> "$ROOT/elsewhere/live.mp4"; ago "$ROOT/elsewhere/live.mp4" 10
bash "$ROOT/app/upload-lives.sh"
check "LIVE Studio recording somewhere else: it notices, and leaves it alone while it records" \
      'grep -qxF "$ROOT/elsewhere/live.mp4" "$ROOT/app/following" && [ -e "$ROOT/elsewhere/live.mp4" ]'
kill "$recpid"; wait "$recpid" 2>/dev/null; sleep 1
bash "$ROOT/app/upload-lives.sh"
check "once that recording stops, it is uploaded too" '[ ! -e "$ROOT/elsewhere/live.mp4" ] && [ ! -s "$ROOT/app/following" ]'

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
bash "$ROOT/app/upload-lives.sh"
check "while a live is recording, nothing uploads (the stream keeps the internet)" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = "$before" ] && [ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && [ -f "$ROOT/app/paused" ]'
ago "$REC/live_now.mp4" 10                               # the live has ended
bash "$ROOT/app/upload-lives.sh"
check "once the recording stops, the uploads carry on" \
      '[ "$(count "$DRIVE" "Salsabeel live *.mp4")" = $((before + 2)) ] && [ ! -f "$ROOT/app/paused" ]'
head -c 4096 /dev/zero > "$REC/big.mp4"; ago "$REC/big.mp4" 10
printf '#!/bin/bash\nif [ "$1" = move ]; then sleep 60; fi\nexec %q "$@"\n' "$RCLONE" > "$ROOT/slow-rclone"   # a slow internet
chmod +x "$ROOT/slow-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$DRIVE" "$ROOT/slow-rclone" > "$ROOT/app/config.sh"
bash "$ROOT/app/upload-lives.sh" & up=$!
sleep 4; head -c 4096 /dev/zero > "$REC/live_again.mp4"   # a live starts mid-upload
for i in $(seq 1 40); do kill -0 "$up" 2>/dev/null || break; head -c 1 /dev/zero >> "$REC/live_again.mp4"; sleep 1; done
check "an upload already running stops when a live starts, and waits" \
      '! kill -0 "$up" 2>/dev/null && [ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && grep -q "A live started, so the upload stopped" "$ROOT/test.log"'
kill "$up" 2>/dev/null; rm -f "$REC/live_again.mp4"; setup "$DRIVE"
bash "$ROOT/app/upload-lives.sh"
check "after the live it carries on, from the beginning of that file" '[ "$(count "$REC/Ready to upload" "*.mp4")" = 0 ]'

# Brandon's PC has copied a live ("Copied - ..."): it is deleted here; the others stay
head -c 4096 /dev/zero > "$DRIVE/Copied - Salsabeel live 2026-11-09 18-00.mp4"
head -c 4096 /dev/zero > "$DRIVE/Salsabeel live 2026-11-10 18-00.mp4"
rm -f "$ROOT/app/cleared-checked"
bash "$ROOT/app/upload-lives.sh"
check "a live Brandon's PC has copied is deleted from this Drive, and nothing else" \
      '[ ! -e "$DRIVE/Copied - Salsabeel live 2026-11-09 18-00.mp4" ] && [ -e "$DRIVE/Salsabeel live 2026-11-10 18-00.mp4" ]'
bash "$ROOT/app/upload-lives.sh" --status-now
check "the status note says how many lives wait in Drive for Brandon's PC" \
      'grep -q "not yet copied by Brandon.s PC: [1-9]" "$DRIVE/Uploader checks/Mac status.txt"'

# Google Drive full: the page says so (not "waiting for the internet")
printf '#!/bin/bash\nif [ "$1" = move ]; then for a in "$@"; do [ -n "${next:-}" ] && echo "ERROR : googleapi: Error 403: The user'"'"'s Drive storage quota has been exceeded., storageQuotaExceeded" >> "$a"; next=; [ "$a" = --log-file ] && next=1; done; exit 1; fi\nexec %q "$@"\n' "$RCLONE" > "$ROOT/full-rclone"
chmod +x "$ROOT/full-rclone"
printf 'WATCH_DIR=%q\nDEST=%q\nRCLONE=%q\nUPDATE_URL=""\n' "$REC" "$DRIVE" "$ROOT/full-rclone" > "$ROOT/app/config.sh"
head -c 4096 /dev/zero > "$REC/when_full.mp4"; ago "$REC/when_full.mp4" 10
bash "$ROOT/app/upload-lives.sh"
check "Google Drive full: the live waits on the Mac, and the page says Drive is full" \
      '[ "$(count "$REC/Ready to upload" "*.mp4")" = 1 ] && grep -q "Google Drive is full" "$PAGE" && grep -q "Google Drive is full" "$ROOT/test.log"'
setup "$DRIVE"; bash "$ROOT/app/upload-lives.sh"

if [ -f manifest.txt ]; then
    check "manifest.txt matches these files (run streaming-mac/build.sh after a change)" \
          '( for n in upload-lives.sh status-page.html; do grep -qx "$(sha "$n")  $n" manifest.txt || exit 1; done )'
fi

echo
if [ "$fails" -eq 0 ]; then echo "SELF-TEST PASSED"; else echo "SELF-TEST FAILED ($fails)"; echo; cat "$ROOT/test.log"; exit 1; fi
