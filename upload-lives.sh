#!/bin/bash
# salsabeel-uploader
# Salsabeel live uploader: one pass. launchd runs it every minute ("Fix Salsabeel uploader" sets that up).
#
# 1. In the recording folder TikTok LIVE Studio saves to (and folders inside it), a video counts as
#    finished when it has not changed for a few minutes and no program has it open any more.
# 2. A finished recording is renamed after the time it started, e.g. "Salsabeel live 2026-11-06 18-02.mp4",
#    and moved into the "Ready to upload" folder beside it.
# 3. rclone moves everything in "Ready to upload" to Google Drive. rclone deletes each file here only
#    once Google Drive has the whole of it. A failed upload stays in "Ready to upload" and is tried
#    again a minute later.
#
# Recordings still in progress are never touched, so nothing uploads during the live.
# While it uploads, a status page (Salsabeel branded) shows in the browser: leave the Mac on, a progress
# bar and the time left. It opens when a live has finished, and again after a restart mid-upload. The Mac
# is kept awake until the upload ends. `upload-lives.sh --preview` shows what the page looks like.
#
# Looking after itself, so nobody has to go to the Mac:
# - If the recording folder has gone (moved or deleted), it is made again, so LIVE Studio can save there.
# - Once an hour it checks UPDATE_URL for a newer version of this script and the status page, and
#   switches to it. Each file must match the SHA-256 in the manifest, and the script must pass `bash -n`.
# - Every 30 minutes, and after each upload, it writes "Mac status.txt" (and the end of its log) to the
#   "Uploader checks" folder inside the Google Drive folder, so Brandon can see from home that it is working.
#   `upload-lives.sh --status-now` sends it straight away.
# - Anything of its own that goes missing (its folder, its settings, rclone, the Google sign-in, the background
#   job's file) is put back from a hidden backup copy, ~/.salsabeel-uploader, which it keeps up to date.
#   The background job starts with a few lines that put its folder back before running this script.
# - If LIVE Studio records somewhere else (its save folder was changed or moved), it sees which video file
#   LIVE Studio has open, and uploads that recording too once it stops.
# - Once an hour it looks for a moved "Salsabeel lives" folder (home folder, Movies) and uploads what is left in it.
# - While a live is on (LIVE Studio recording), it uploads nothing, so the stream keeps all the internet. An
#   upload already running stops when a live starts, and carries on by itself once the recording stops.
# - Brandon's PC copies each live into his own Google Drive, then renames the original here "Copied - ...".
#   Every 10 minutes this deletes those for good (only files it uploaded itself), so this Drive never fills.
#   If it is full anyway, the lives wait on this Mac and the status page says so.
# - A short recording (under MIN_LIVE_MB, or under MIN_LIVE_SECONDS from start to stop) is a test, not a
#   live: it goes to "Uploader checks/Short recordings" in Drive, where Brandon's PC never makes clips of it.
# - A new version can take over mid-upload: the upload stops and starts again with it a minute later.
# - When Google Drive says how much space is left, it uploads one recording at a time, oldest first, and only
#   those that fit (with DRIVE_MARGIN_MB to spare). Nothing is sent that Drive would refuse.
# None of this needs any app open: launchd runs it every minute while the Mac is on and signed in.
# Written for macOS's own bash 3.2; runs on Linux too, which is how it is tested (self-test.command).
set -u

APP_DIR="${SALSABEEL_UPLOADER_DIR:-$HOME/Library/Application Support/SalsabeelLiveUploader}"
LOG="${SALSABEEL_UPLOADER_LOG:-$HOME/Library/Logs/SalsabeelLiveUploader.log}"
BACKUP="${SALSABEEL_UPLOADER_BACKUP:-$HOME/.salsabeel-uploader}"
LABEL="com.salsabeel.live-uploader"
PLIST="${SALSABEEL_UPLOADER_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
RECORDER="${SALSABEEL_UPLOADER_RECORDER:-live ?studio}"   # LIVE Studio's programs, by their command line (not the TikTok app)
PREFIX="Salsabeel live"
QUIET_MINUTES=2
BWLIMIT=""
WATCH_DIR="$HOME/Salsabeel lives/Recordings"   # the usual set-up; config.sh says otherwise if not
DEST="salsabeel-drive:Salsabeel lives"
RCLONE=""
ONLY_NEW_SINCE=""     # set when the recording folder also holds other videos: older ones are left alone
UPDATE_URL="https://raw.githubusercontent.com/BrandonLeeRutlidge/salsabeel-uploader/main"
UPDATE_EVERY=600       # how often it looks for a new version (just manifest.txt; the rest only when it changed)
MIN_LIVE_MB="${SALSABEEL_UPLOADER_MIN_LIVE_MB:-100}"   # smaller than this, or shorter than MIN_LIVE_SECONDS,
MIN_LIVE_SECONDS=600                                   # is a test recording, not a live
DRIVE_MARGIN_MB=200    # room kept free in Google Drive
# Uploading during a live: as much of the line as the stream can spare. LIVE_UPLOAD=off waits for the live to end.
LIVE_UPLOAD=on
LIVE_UPLOAD_MAX_MBIT=20        # the ceiling is the lowest of: this hard cap ("" = none) ...
LIVE_LINE_SHARE=40             # ... this % of the line's measured upload speed ...
LIVE_STREAM_RESERVE_MBIT=10    # ... and the line less this, kept for the stream (LIVE Studio sends about 4-6 Mbit/s)
LIVE_UPLOAD_MIN_MBIT=1.5       # it starts here, and never sets less than this unless the line is in trouble
LIVE_UNKNOWN_MAX_MBIT=4        # the most until the line's speed has been measured
LIVE_UPLOAD_FLOOR_KBIT=500     # halving below this pauses instead
LIVE_RAMP_SECONDS=120          # this long without trouble: 25% faster, up to the ceiling
LIVE_GUARD_EVERY=25            # seconds between checks on the line's delay ...
LIVE_GUARD_FAST_EVERY=10       # ... and above 4 Mbit/s
LIVE_GUARD_MS=50               # the delay up by this much over the baseline ...
LIVE_GUARD_LOSS=2              # ... or more pings lost than this %: half speed at once; twice: the minimum; three times: a pause
LIVE_PAUSE_SECONDS=600         # the pause
LIVE_RELAX_SECONDS=600         # after trouble it stays below that speed for this long
SLEEP_GAP_SECONDS=600          # no run for this long: the Mac was asleep (or off)
PING_HOSTS="${SALSABEEL_UPLOADER_PING_HOSTS:-1.1.1.1 8.8.8.8}"
PING="${SALSABEEL_UPLOADER_PING:-ping}"
STATUS_IDLE_EVERY=1800   # the status note: every 30 minutes when nothing is happening,
STATUS_BUSY_EVERY=300    # every 5 while something is (an upload, a live, Drive full)
STATUS_EVERY=$STATUS_IDLE_EVERY
CHECKS_FOLDER="Uploader checks"
TEMPLATE="${SALSABEEL_UPLOADER_TEMPLATE:-$APP_DIR/status-page.html}"
PAGE="$APP_DIR/Salsabeel live uploader.html"
export LC_NUMERIC=C
shopt -u patsub_replacement 2>/dev/null || true
# config.sh sets WATCH_DIR, DEST (an rclone destination, e.g. "salsabeel-drive:Salsabeel lives") and RCLONE,
# and may set ONLY_NEW_SINCE and UPDATE_URL ("" turns updates off).
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
mkdir -p "$(dirname "$LOG")" "$APP_DIR"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
if [ "$(uname)" = "Darwin" ]; then PREV_RUN=$(stat -f %m "$APP_DIR/last-run" 2>/dev/null); else PREV_RUN=$(stat -c %Y "$APP_DIR/last-run" 2>/dev/null); fi
touch "$APP_DIR/last-run"     # "Fix Salsabeel uploader" reads this to see that the Mac really runs it

# Put back anything of its own that has gone missing (moved or deleted), from the backup copy.
RESTORED=""
for f in config.sh status-page.html VERSION self-test.command show-log.command uninstall.command; do
    if [ ! -f "$APP_DIR/$f" ] && [ -f "$BACKUP/$f" ] && cp -p "$BACKUP/$f" "$APP_DIR/$f"; then RESTORED="$RESTORED $f"; fi
done
if [ ! -x "$APP_DIR/bin/rclone" ] && [ -x "$BACKUP/bin/rclone" ] && mkdir -p "$APP_DIR/bin" &&
   cp -p "$BACKUP/bin/rclone" "$APP_DIR/bin/rclone"; then RESTORED="$RESTORED bin/rclone"; fi
if [ -n "$RESTORED" ]; then log "Put back from the backup copy (moved or deleted?):$RESTORED"; fi
if [ -f "$APP_DIR/config.sh" ]; then . "$APP_DIR/config.sh"; fi

if [ "$(uname)" = "Darwin" ]; then
    mtime() { stat -f %m "$1"; }
    fsize() { stat -f %z "$1"; }
    btime() { stat -f %B "$1"; }
    stamp() { date -r "$1" '+%Y-%m-%d %H-%M'; }
    boot_id() { sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+).*/\1/'; }
    OPEN_PAGE="${SALSABEEL_UPLOADER_OPEN:-open}"
else
    mtime() { stat -c %Y "$1"; }
    fsize() { stat -c %s "$1"; }
    btime() { local b; b=$(stat -c %W "$1"); if [ "${b:-0}" -le 0 ]; then b=$(stat -c %Y "$1"); fi; echo "$b"; }
    stamp() { date -d "@$1" '+%Y-%m-%d %H-%M'; }
    boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo none; }
    OPEN_PAGE="${SALSABEEL_UPLOADER_OPEN:-:}"
fi
is_video() { case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in *.mp4|*.mov|*.mkv|*.flv) return 0 ;; esac; return 1; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

# --- The status page -------------------------------------------------------------------------
LEAVE_ON="Please leave the Mac on, with the lid open, until this says done. You can carry on using it."
FILES_LABEL=""
write_status() {   # state badge heading message percent detail title
    [ -f "$TEMPLATE" ] || return 0
    local page refresh='<meta http-equiv="refresh" content="3">'
    if [ "$1" = "done" ]; then refresh=""; fi
    page=$(cat "$TEMPLATE")
    page=${page//__REFRESH__/$refresh}
    page=${page//__STATE__/$1}
    page=${page//__BADGE__/$2}
    page=${page//__HEADING__/$3}
    page=${page//__MESSAGE__/$4}
    page=${page//__PERCENT__/$5}
    page=${page//__DETAIL__/$6}
    page=${page//__TITLE__/$7}
    page=${page//__FILE__/$FILES_LABEL}
    local notice=""
    if [ -n "$(find "${READY:-/nonexistent}" -type f ! -name '.*' 2>/dev/null | head -n 1)" ]; then
        notice="Please leave the laptop open after the last live until uploads say Done"
    fi
    page=${page//__NOTICE__/$notice}
    page=${page//__LINE__/Line: $(line_report 2>/dev/null)}
    printf '%s\n' "$page" > "$PAGE.tmp" && mv -f "$PAGE.tmp" "$PAGE"
}
open_page() { "$OPEN_PAGE" "$PAGE" >/dev/null 2>&1 || true; boot_id > "$APP_DIR/page-opened-boot"; }
human_size() {   # "8.027 MiB" -> "8 MB", "1.234 GiB" -> "1.2 GB"
    case "${1#* }" in
        TiB|TB) printf '%.1f TB' "${1% *}" ;; GiB|GB) printf '%.1f GB' "${1% *}" ;;
        MiB|MB) printf '%.0f MB' "${1% *}" ;; KiB|kB|KB) printf '%.0f KB' "${1% *}" ;; *) printf '%s' "$1" ;;
    esac
}
time_left() {   # rclone's "1h2m3s" -> "about 1 hour 2 minutes left"
    local h=0 m=0
    case "$1" in ""|"-") echo "working out the time left"; return ;; esac
    if [[ $1 =~ ([0-9]+)h ]]; then h=${BASH_REMATCH[1]}; fi
    if [[ $1 =~ ([0-9]+)m ]]; then m=${BASH_REMATCH[1]}; fi
    if [ "$h" -gt 0 ]; then
        printf 'about %s hour%s %s minute%s left' "$h" "$([ "$h" = 1 ] || echo s)" "$m" "$([ "$m" = 1 ] || echo s)"
    elif [ "$m" -gt 0 ]; then
        printf 'about %s minute%s left' "$m" "$([ "$m" = 1 ] || echo s)"
    else
        printf 'less than a minute left'
    fi
}
status_preparing() { write_status preparing "Live finished" "Getting today&#39;s live ready to upload" "$LEAVE_ON" 0 "Starting the upload" "Starting upload · Salsabeel"; }
status_uploading() {   # percent "done / total" eta
    local detail="$(human_size "${2% / *}") of $(human_size "${2#* / }") · $(time_left "$3")"
    write_status uploading "Uploading" "Uploading today&#39;s live" "$LEAVE_ON" "$1" "$detail" "Uploading $1% · Salsabeel"
    NOW_LINE="Uploading $1% ($(human_size "${2% / *}") of $(human_size "${2#* / }"), $(time_left "$3"))"
}
status_done() { write_status done "Done" "The live is in Google Drive" "All done. You can turn the Mac off now." 100 "Uploaded at $(date '+%H:%M')" "Done · Salsabeel"; }
status_paused() { write_status retry "Paused for the live" "Upload paused while you are live" "A live is on, so the upload waits and carries on by itself once the recording stops. Leave the Mac on." "${pct:-0}" "Carries on after the live" "Paused · Salsabeel"; }
status_full() { write_status retry "Google Drive is full" "Waiting for space in Google Drive" "The Google Drive is full right now. The live is safe on this Mac and uploads by itself once there is space. You can turn the Mac off." "${pct:-0}" "Tries again every minute" "Drive full · Salsabeel"; }
status_retry() { write_status retry "Not uploaded yet" "Waiting for the internet" "Google Drive could not be reached. It tries again by itself every minute, so leave the Mac on and online." "${1:-0}" "Next try in about a minute" "Waiting · Salsabeel"; }

if [ "${1:-}" = "--preview" ]; then   # what the page looks like mid-upload
    TEMPLATE="${SALSABEEL_UPLOADER_TEMPLATE:-$(dirname "$0")/status-page.html}"
    PAGE="${TMPDIR:-/tmp}/Salsabeel live uploader (preview).html"
    FILES_LABEL="Salsabeel live 2026-11-06 18-02.mp4"
    status_uploading 42 "2.384 GiB / 5.678 GiB" "6m12s"
    "$OPEN_PAGE" "$PAGE" >/dev/null 2>&1 || true
    echo "$PAGE"
    exit 0
fi

notify() {
    if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"$1\" with title \"Salsabeel live uploader\"" >/dev/null 2>&1 || true
    fi
}

# Warn once, not every minute, while something is missing.
warn_once() {
    if [ "$(cat "$APP_DIR/warned" 2>/dev/null)" != "$1" ]; then log "$1"; echo "$1" > "$APP_DIR/warned"; fi
}

# --- Videos in the recording folder --------------------------------------------------------------
READY="$WATCH_DIR/Ready to upload"
recordings() {   # every video in the recording folder and up to 2 folders down, but not "Ready to upload"
    find "$WATCH_DIR" -maxdepth 3 \( -path "$READY" -o -name '.*' \) -prune -o -type f \
         \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.flv' \) -print 2>/dev/null
}
count_videos() { find "$1" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

# --- Updates from Brandon ----------------------------------------------------------------------
update_if_due() {
    [ -n "$UPDATE_URL" ] && command -v curl >/dev/null 2>&1 || return 0
    local checked="$APP_DIR/update-checked" now_s tmp version current sum name ok=1 names=""
    now_s=$(date +%s)
    if [ -f "$checked" ] && [ $(( now_s - $(mtime "$checked") )) -lt "$UPDATE_EVERY" ]; then return 0; fi
    touch "$checked"
    tmp=$(mktemp -d "$APP_DIR/.update.XXXXXX") || return 0
    if ! curl -fsSL --connect-timeout 10 --max-time 20 -o "$tmp/manifest.txt" "$UPDATE_URL/manifest.txt" 2>/dev/null; then
        rm -rf "$tmp"; return 0
    fi
    version=$(sed -n 's/^version //p' "$tmp/manifest.txt" | head -n 1)
    current=$(cat "$APP_DIR/VERSION" 2>/dev/null)
    if [ -z "$version" ] || [ "$version" = "$current" ]; then rm -rf "$tmp"; return 0; fi
    while read -r sum name; do
        case "$name" in upload-lives.sh|status-page.html) ;; *) continue ;; esac   # nothing else is replaced
        if curl -fsSL --connect-timeout 10 --max-time 120 -o "$tmp/$name" "$UPDATE_URL/$name" 2>/dev/null &&
           [ "$(sha256 "$tmp/$name")" = "$sum" ]; then
            names="$names $name"
        else
            ok=0
        fi
    done < "$tmp/manifest.txt"
    if [ "$ok" = 1 ] && [ -f "$tmp/upload-lives.sh" ] && bash -n "$tmp/upload-lives.sh" 2>/dev/null &&
       grep -qx '# salsabeel-uploader' "$tmp/upload-lives.sh"; then
        for name in $names; do
            chmod 755 "$tmp/$name"
            mv -f "$tmp/$name" "$APP_DIR/$name"   # a new file: this run carries on with the old one
        done
        echo "$version" > "$APP_DIR/VERSION"
        log "Updated itself from version ${current:-unknown} to $version."
        UPDATED=1
        STATUS_NOW=1
    else
        warn_once "An update to version $version did not download or check out, so it was not used. Still on ${current:-unknown}."
    fi
    rm -rf "$tmp"
}

# --- The status note in Google Drive -----------------------------------------------------------------
STATUS_NOW=0
NOW_LINE=""    # one plain sentence for the note's "Now:" line (the PC status app shows it word for word)
BUSY=""        # set when a live is on: the note goes every 5 minutes, not 30
plural() { if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }   # 1 live, 2 lives
now_live() { NOW_LINE="A live is on: $(plural "$1" "upload waits" "uploads wait") until it stops"; BUSY=1; }
now_full() { NOW_LINE="Google Drive is full: $(plural "$1" "live waits" "lives wait") on the Mac"; }
send_status() {
    local note="$APP_DIR/Mac status.txt" drive mac waiting=0 ready=0 f
    mac=$(scutil --get ComputerName 2>/dev/null || hostname)
    if [ -d "$WATCH_DIR" ]; then waiting=$(recordings | wc -l | tr -d ' '); fi
    if [ -d "$READY" ]; then ready=$(count_videos "$READY"); fi
    drive=$("$RCLONE" about "${DEST%%:*}:" --contimeout 15s --timeout 30s 2>/dev/null | sed 's/^/  /')
    IN_DRIVE=$("$RCLONE" lsf "$DEST" --files-only --contimeout 15s --timeout 30s 2>/dev/null | grep -v '^Copied - ' |
               while IFS= read -r f; do is_video "$f" && echo "$f"; done | grep -c . || true)
    {
        echo "Salsabeel live uploader: status from the streaming Mac"
        echo
        echo "Sent:               $(date '+%Y-%m-%d %H:%M') (every 5 minutes while busy, otherwise every 30, while the Mac is on and online)"
        echo "Now:                ${NOW_LINE:-Nothing to upload}"
        if [ -f "$APP_DIR/last-sleep" ] && [ $(( $(date +%s) - $(mtime "$APP_DIR/last-sleep") )) -lt 86400 ]; then
            echo "Asleep:             $(cat "$APP_DIR/last-sleep")"
        fi
        echo "Line:               $(line_report)"
        echo "Mac:                $mac"
        echo "Version:            $(cat "$APP_DIR/VERSION" 2>/dev/null || echo unknown)"
        echo "Recording folder:   $WATCH_DIR"
        echo "  videos in it:     $waiting (recording, or stopped less than ${QUIET_MINUTES} minutes ago)"
        echo "Waiting to upload:  $ready"
        if [ -n "${IN_DRIVE+x}" ]; then echo "In Google Drive, not yet copied by Brandon's PC: $IN_DRIVE"; fi
        if [ -d "$READY" ]; then for f in "$READY"/*; do [ -f "$f" ] && echo "  $(basename "$f")"; done; fi
        if [ -s "$FOLLOW" ]; then
            echo "LIVE Studio recording outside the folder (uploads when it stops):"
            sed 's/^/  /' "$FOLLOW"
        fi
        echo "Backup copy:        $( [ -f "$BACKUP/upload-lives.sh" ] && echo "yes, in $BACKUP" || echo "not yet")"
        echo "Free on the Mac:    $(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
        echo "Google Drive space:"
        echo "${drive:-  (not available)}"
        echo
        echo "The end of the log:"
        tail -n 40 "$LOG" 2>/dev/null | sed 's/^/  /'
    } > "$note"
    if "$RCLONE" copyto "$note" "$DEST/$CHECKS_FOLDER/Mac status.txt" --contimeout 15s --timeout 60s \
           --retries 1 --low-level-retries 2 >/dev/null 2>&1; then
        touch "$APP_DIR/status-sent"
        return 0
    fi
    return 1
}
status_if_due() {
    local sent="$APP_DIR/status-sent"
    STATUS_EVERY=$STATUS_IDLE_EVERY
    if [ -n "$BUSY" ] || [ -f "$APP_DIR/paused" ] || [ -f "$APP_DIR/full-noted" ] ||
       [ -n "$(find "$READY" -type f ! -name '.*' 2>/dev/null | head -n 1)" ]; then
        STATUS_EVERY=$STATUS_BUSY_EVERY
    fi
    if [ "$STATUS_NOW" = 1 ] || [ ! -f "$sent" ] || [ $(( $(date +%s) - $(mtime "$sent") )) -ge "$STATUS_EVERY" ]; then
        send_status || true
    fi
}

# --- Looking after itself ------------------------------------------------------------------------
FOLLOW="$APP_DIR/following"
if [ -n "$RESTORED" ]; then STATUS_NOW=1; fi
find_rclone() {
    local p
    for p in "$(command -v "${RCLONE:-rclone}" 2>/dev/null)" "$APP_DIR/bin/rclone" "$BACKUP/bin/rclone" \
             "$(command -v rclone 2>/dev/null)" /opt/homebrew/bin/rclone /usr/local/bin/rclone; do
        if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then echo "$p"; return 0; fi
    done
    return 1
}
if ! found=$(find_rclone); then warn_once "rclone is missing: run \"Fix Salsabeel uploader\"."; exit 0; fi
if [ -n "$RCLONE" ] && [ "$found" != "$RCLONE" ] && [ ! -x "$RCLONE" ]; then
    log "rclone had gone from \"$RCLONE\"; using \"$found\"."
fi
RCLONE="$found"
REMOTE="${DEST%%:*}"
is_remote() { case "$REMOTE" in "$DEST"|*/*|"") return 1 ;; esac; return 0; }   # not a plain folder (tests)
rclone_conf() { "$RCLONE" config file 2>/dev/null | tail -n 1; }
remote_section() { awk -v h="[$REMOTE]" '/^\[/ { p = ($0 == h) } p' "$1" 2>/dev/null; }

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
write_plist() {   # the background job. Its first lines put this folder back from the backup (or online) if it has gone.
    local boot
    boot=$(cat <<'BOOT'
if [ ! -f "$A/upload-lives.sh" ]; then
  mkdir -p "$A"
  if [ -f "$B/upload-lives.sh" ]; then cp -Rp "$B/." "$A/"
  elif [ -n "$U" ] && curl -fsSL -m 120 -o "$A/new.sh" "$U/upload-lives.sh" && bash -n "$A/new.sh" &&
       grep -qx '# salsabeel-uploader' "$A/new.sh"; then mv -f "$A/new.sh" "$A/upload-lives.sh"
  fi
fi
exec /bin/bash "$A/upload-lives.sh"
BOOT
)
    boot="A=$(printf %q "$APP_DIR"); B=$(printf %q "$BACKUP"); U=$(printf %q "$UPDATE_URL")
$boot"
    mkdir -p "$(dirname "$PLIST")" || return 1
    cat > "$PLIST.tmp" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>$(xml "$boot")</string>
    </array>
    <key>StartInterval</key><integer>60</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$(xml "$(dirname "$LOG")/SalsabeelLiveUploader.out.log")</string>
    <key>StandardErrorPath</key><string>$(xml "$(dirname "$LOG")/SalsabeelLiveUploader.out.log")</string>
</dict>
</plist>
EOF
    mv -f "$PLIST.tmp" "$PLIST"
}
backup_self() {   # keep the hidden copy up to date (only what changed is copied)
    local f conf
    mkdir -p "$BACKUP/bin" 2>/dev/null || return 0
    chmod 700 "$BACKUP" 2>/dev/null
    for f in upload-lives.sh status-page.html config.sh VERSION self-test.command show-log.command uninstall.command; do
        if [ -f "$APP_DIR/$f" ] && ! cmp -s "$APP_DIR/$f" "$BACKUP/$f"; then cp -p "$APP_DIR/$f" "$BACKUP/$f"; fi
    done
    if [ -x "$APP_DIR/bin/rclone" ] && { [ ! -x "$BACKUP/bin/rclone" ] || [ "$APP_DIR/bin/rclone" -nt "$BACKUP/bin/rclone" ]; }; then
        cp -p "$APP_DIR/bin/rclone" "$BACKUP/bin/rclone"
    fi
    if is_remote; then
        conf=$(rclone_conf)
        if [ -f "$conf" ]; then
            ( umask 077; remote_section "$conf" > "$BACKUP/rclone.conf.new" )
            if [ -s "$BACKUP/rclone.conf.new" ] && ! cmp -s "$BACKUP/rclone.conf.new" "$BACKUP/rclone.conf"; then
                mv -f "$BACKUP/rclone.conf.new" "$BACKUP/rclone.conf"
            else
                rm -f "$BACKUP/rclone.conf.new"
            fi
        fi
    fi
    if [ ! -f "$PLIST" ]; then
        write_plist && log "The background job's file had gone, so it was written again."
    elif ! grep -q '<string>-c</string>' "$PLIST" 2>/dev/null; then
        write_plist && log "The background job's file now puts this folder back if it goes (from the next sign-in)."
    fi
    return 0
}
if [ "${1:-}" = "--install" ]; then write_plist && backup_self; exit $?; fi
if is_remote && ! "$RCLONE" listremotes 2>/dev/null | grep -qxF "$REMOTE:"; then
    if [ -s "$BACKUP/rclone.conf" ]; then
        conf=$(rclone_conf)
        mkdir -p "$(dirname "$conf")"
        { if [ -s "$conf" ]; then echo; fi; cat "$BACKUP/rclone.conf"; } >> "$conf"
        chmod 600 "$conf" 2>/dev/null
        log "The Google sign-in had gone from rclone's settings, so it was put back from the backup copy."
        STATUS_NOW=1
    else
        warn_once "Not signed in to Google: run \"Fix Salsabeel uploader\"."; exit 0
    fi
fi
if [ ! -d "$WATCH_DIR" ]; then
    if mkdir -p "$WATCH_DIR" 2>/dev/null; then
        log "The recording folder \"$WATCH_DIR\" had gone (moved or deleted?), so it was made again."
        STATUS_NOW=1
    else
        warn_once "Waiting: the recording folder \"$WATCH_DIR\" is not there and could not be made."
        exit 0
    fi
fi
rm -f "$APP_DIR/warned"
backup_self


# --- Uploading during a live -------------------------------------------------------------------------
kbit_of() { awk -v m="$1" 'BEGIN { printf "%d", m * 1000 }'; }        # "1.5" Mbit/s -> 1500 kbit/s
mbit_of() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1000 }'; }      # 1500 kbit/s -> "1.5"
rate_of() { echo "$(( $1 * 125 / 1024 ))k"; }                          # kbit/s -> rclone's KiB/s
line_known_kbit() {   # the line's upload speed: the middle of the last 5 full-speed uploads; "" if none yet
    tail -n 5 "$APP_DIR/line-speeds" 2>/dev/null | grep -E '^[0-9]+$' | sort -n |
        awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)] }'
}
line_report() {   # "87 Mbit/s up (measured 20:40, last 5 uploads)" or "not measured yet"
    local l n
    l=$(line_known_kbit)
    if [ -z "$l" ]; then echo "not measured yet"; return; fi
    n=$(tail -n 5 "$APP_DIR/line-speeds" | grep -cE '^[0-9]+$')
    echo "$(awk -v k="$l" 'BEGIN { if (k >= 10000) printf "%.0f", k / 1000; else printf "%.1f", k / 1000 }') Mbit/s up (measured $(clock_of "$(mtime "$APP_DIR/line-speeds")" '%H:%M'), last $(plural "$n" upload uploads))"
}
cap_min() { kbit_of "$LIVE_UPLOAD_MIN_MBIT"; }
reserve() { kbit_of "$LIVE_STREAM_RESERVE_MBIT"; }
ceiling_kbit() {   # the lowest of the hard cap, LIVE_LINE_SHARE% of the line, and the line less the reserve; at least the minimum
    local l c q lo hard
    l=$(line_known_kbit); lo=$(cap_min)
    if [ -z "$l" ]; then
        c=$(kbit_of "$LIVE_UNKNOWN_MAX_MBIT")
    else
        c=$(( l * LIVE_LINE_SHARE / 100 ))
        q=$(( l - $(reserve) )); if [ "$q" -lt "$c" ]; then c=$q; fi
    fi
    if [ -n "$LIVE_UPLOAD_MAX_MBIT" ]; then hard=$(kbit_of "$LIVE_UPLOAD_MAX_MBIT"); if [ "$c" -gt "$hard" ]; then c=$hard; fi; fi
    if [ "$c" -lt "$lo" ]; then c=$lo; fi
    echo "$c"
}
ping_host() {   # 5 pings; one line per reply, its time in ms
    if [ "$(uname)" = "Darwin" ]; then "$PING" -c 5 -t 8 "$1"; else "$PING" -c 5 -w 8 "$1"; fi 2>/dev/null |
        sed -nE 's/.*time[=<]([0-9.]+) ?ms.*/\1/p'
}
measure_line() {   # sets LAT (middle delay in ms, "" if nothing came back) and LOSS (% of pings lost)
    local h i=0 pids="" p n total
    for h in $PING_HOSTS; do ping_host "$h" > "$APP_DIR/ping.$i" & pids="$pids $!"; i=$((i + 1)); done
    for p in $pids; do wait "$p" 2>/dev/null; done
    cat "$APP_DIR"/ping.[0-9]* > "$APP_DIR/pings" 2>/dev/null; rm -f "$APP_DIR"/ping.[0-9]*
    total=$(( i * 5 )); n=$(grep -c . "$APP_DIR/pings" 2>/dev/null || true); n=${n:-0}
    LOSS=0
    if [ "$total" -gt 0 ] && [ "$n" -lt "$total" ]; then LOSS=$(( (total - n) * 100 / total )); fi
    LAT=$(sort -n "$APP_DIR/pings" 2>/dev/null | awk '{ a[NR] = $1 } END { if (NR) printf "%d", a[int((NR + 1) / 2)] + 0.5 }')
}
live_name() { echo "${1%.*}"; }   # "Salsabeel live 2026-11-07 18-02.mp4" -> "Salsabeel live 2026-11-07 18-02"
current_file() {   # the first file of this upload not yet in Google Drive
    local f
    while IFS= read -r f; do if [ -e "$READY/$f" ]; then basename "$f"; return; fi; done < "$APP_DIR/to-upload"
}
RC_URL=""
rc_bwlimit() {   # change rclone's speed while it runs (its remote control, local only, file actions refused)
    if [ -z "$RC_URL" ]; then
        RC_URL=$(sed -nE 's#.*Serving remote control on (http://127\.0\.0\.1:[0-9]+/).*#\1#p' "$PROGRESS" 2>/dev/null | head -n 1)
    fi
    [ -n "$RC_URL" ] && "$RCLONE" rc --url "$RC_URL" --timeout 10s core/bwlimit "rate=$1" >/dev/null 2>&1
}
full_rate() { echo "${BWLIMIT:-off}"; }
status_slow() {   # percent "done / total" eta
    local detail="$(human_size "${2% / *}") of $(human_size "${2#* / }") · $(mbit_of "$cap") Mbit/s"
    write_status uploading "Uploading slowly" "Uploading slowly during the live" \
        "A live is on, so this uploads slowly and keeps the stream smooth. Leave the Mac on." "$1" "$detail" "Uploading slowly $1% · Salsabeel"
    NOW_LINE="A live is on: uploading slowly ($(mbit_of "$cap") Mbit/s), $(live_name "$(current_file)") $1%"
}
status_guarded() {   # minutes
    write_status retry "Paused for the stream" "Upload paused to protect the stream" \
        "The internet looked busy, so the upload stopped for a few minutes to keep the live smooth. It carries on by itself." \
        "${pct:-0}" "Back in about $1 minutes" "Paused · Salsabeel"
    NOW_LINE="A live is on: upload paused to protect the stream (back in $1 min)"
}

note_sleep() {   # the Mac slept (or was off) between runs while lives were waiting: say so
    local n gap fmt
    [ -n "$PREV_RUN" ] || return 0
    gap=$(( $(date +%s) - PREV_RUN ))
    [ "$gap" -ge "$SLEEP_GAP_SECONDS" ] || return 0
    n=$(cat "$APP_DIR/waiting-count" 2>/dev/null); n=${n:-0}
    [ "$n" -gt 0 ] 2>/dev/null || return 0
    fmt='%H:%M'; if [ "$gap" -ge 72000 ]; then fmt='%a %d %b %H:%M'; fi
    echo "the Mac slept from $(clock_of "$PREV_RUN" "$fmt") to $(clock_of "$(date +%s)" "$fmt") with $(plural "$n" "live" "lives") waiting" > "$APP_DIR/last-sleep"
    log "Asleep: $(cat "$APP_DIR/last-sleep"). Please leave the laptop open after the last live until uploads say Done."
    STATUS_NOW=1
}
clock_of() { if [ "$(uname)" = "Darwin" ]; then date -r "$1" "+$2"; else date -d "@$1" "+$2"; fi; }
if [ "${1:-}" = "--live-ceiling" ]; then mbit_of "$(ceiling_kbit)"; exit 0; fi   # (for the self-test)
if [ "${1:-}" = "--status-now" ]; then send_status; exit $?; fi
note_sleep

# One copy at a time (launchd already avoids overlaps; this covers a manual run as well).
PIDFILE="$APP_DIR/running.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then exit 0; fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

update_if_due

mkdir -p "$READY"
now=$(date +%s)
shopt -s nullglob
finished=0

is_short() {   # a test recording: small, or only a few minutes from start (created) to stop (last written)
    local f="$1" length
    if [ $(( $(fsize "$f") / 1048576 )) -lt "$MIN_LIVE_MB" ]; then return 0; fi
    length=$(( $(mtime "$f") - $(btime "$f") ))
    [ "$length" -gt 0 ] && [ "$length" -lt "$MIN_LIVE_SECONDS" ]
}
take_if_finished() {   # path [since]: a stopped recording goes into "Ready to upload" with a date-and-time name
    local f="$1" ext name target n dir="$READY" short=""
    [ -f "$f" ] && [ -s "$f" ] || return 1
    [ $(( now - $(mtime "$f") )) -ge $(( QUIET_MINUTES * 60 )) ] || return 1
    if [ "${2:-}" = since ] && [ -n "$ONLY_NEW_SINCE" ] && [ "$(mtime "$f")" -lt "$ONLY_NEW_SINCE" ]; then return 1; fi
    if lsof -- "$f" >/dev/null 2>&1; then return 1; fi   # LIVE Studio still has it open
    ext=$(printf '%s' "${f##*.}" | tr 'A-Z' 'a-z')
    name="$PREFIX $(stamp "$(btime "$f")")"
    if is_short "$f"; then   # uploaded beside the status note, never with the lives
        short=1; dir="$READY/$CHECKS_FOLDER/Short recordings"; name="Short recording $(stamp "$(btime "$f")")"
        mkdir -p "$dir"
    fi
    target="$dir/$name.$ext"
    n=2
    while [ -e "$target" ]; do target="$dir/$name ($n).$ext"; n=$((n + 1)); done
    if mv -n "$f" "$target" 2>/dev/null && [ -e "$target" ] && [ ! -e "$f" ]; then
        if [ -n "$short" ]; then
            log "Short recording (a test?): \"${f#"$WATCH_DIR"/}\" goes to \"$CHECKS_FOLDER/Short recordings\", not with the lives."
        else
            log "Recording finished: \"${f#"$WATCH_DIR"/}\" is now \"$(basename "$target")\""
            finished=$((finished + 1))
        fi
        return 0
    fi
    warn_once "Could not move \"$f\" (macOS may be blocking access to that folder)."
    return 1
}
live_studio_videos() {   # the video files LIVE Studio is recording to right now (app caches left out)
    local pids p t                # only in the recording folder, or growing: scene media it merely holds open is not a live
    t=$(date +%s)
    pids=$(ps -axo pid=,args= 2>/dev/null | awk -v m="$RECORDER" '{ l = tolower($0) }
               l ~ m && l !~ /^ *[0-9]+ awk / && l !~ /rclone|upload-lives|fix salsabeel/ { print $1 }' | paste -sd, -)
    [ -n "$pids" ] || return 0
    lsof -nP -p "$pids" -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u | while IFS= read -r p; do
        is_video "$p" && [ -f "$p" ] || continue
        case "$p" in */Library/*|/System/*) continue ;; esac
        if [ -z "${SALSABEEL_UPLOADER_TEST:-}" ]; then   # macOS's temporary folders (the self-test works in one)
            case "$p" in /private/var/folders/*|/var/folders/*) continue ;; esac
        fi
        case "$p" in "$WATCH_DIR"/*) echo "$p"; continue ;; esac
        if grep -qxF -- "$p" "$FOLLOW" 2>/dev/null || [ $(( t - $(mtime "$p") )) -lt 90 ]; then echo "$p"; fi
    done
}
recording_now() {   # is a live on? LIVE Studio has a recording open, or a recording changed in the last 90 seconds
    local f t on=""
    on=$(live_studio_videos | head -n 1)
    if [ -z "$on" ]; then
        t=$(date +%s)
        while IFS= read -r f; do
            if [ -f "$f" ] && [ $(( t - $(mtime "$f") )) -lt 90 ]; then on=$f; break; fi
        done < <(recordings; if [ -s "$FOLLOW" ]; then cat "$FOLLOW"; fi)
    fi
    if [ -n "$on" ]; then
        if [ ! -f "$APP_DIR/live-on" ]; then echo "$on" > "$APP_DIR/live-on"; log "Live started (file \"$on\")."; fi
        return 0
    fi
    if [ -f "$APP_DIR/live-on" ]; then log "Live stopped (\"$(cat "$APP_DIR/live-on")\")."; rm -f "$APP_DIR/live-on"; fi
    return 1
}
follow_live_studio() {   # video files LIVE Studio has open outside the recording folder
    local p
    live_studio_videos | while IFS= read -r p; do
        case "$p" in "$WATCH_DIR"/*) continue ;; esac
        if ! grep -qxF -- "$p" "$FOLLOW" 2>/dev/null; then
            echo "$p" >> "$FOLLOW"
            log "LIVE Studio is recording to \"$p\", outside the recording folder: it uploads when the recording stops."
        fi
    done
}
rescue_moved() {   # once an hour: recordings left in a moved "Salsabeel lives" folder (never in Desktop,
    local f        # Documents or Downloads, so macOS never asks about them in the background)
    if [ -f "$APP_DIR/moved-checked" ] && [ $(( now - $(mtime "$APP_DIR/moved-checked") )) -lt 3600 ]; then return 0; fi
    touch "$APP_DIR/moved-checked"
    find "$HOME" -maxdepth 3 \( -path "$HOME/Library" -o -path "$HOME/Desktop" -o -path "$HOME/Documents" \
         -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" -o -path "$HOME/Music" -o -name '.*' \) -prune \
         -o -type d -name 'Salsabeel lives' -print 2>/dev/null | while IFS= read -r d; do
        [ -d "$d/Recordings" ] || continue
        case "$WATCH_DIR" in "$d/Recordings"|"$d/Recordings"/*) continue ;; esac
        find "$d/Recordings" -maxdepth 3 -type f ! -name '.*' 2>/dev/null
    done > "$APP_DIR/moved-videos"
    while IFS= read -r f; do
        if is_video "$f" && take_if_finished "$f"; then log "  (that one was in a moved \"Salsabeel lives\" folder)"; fi
    done < "$APP_DIR/moved-videos"
}

clear_copied() {   # lives Brandon's PC has copied to its own Drive ("Copied - ..."): delete them here for good
    local f n=0
    if [ -f "$APP_DIR/cleared-checked" ] && [ $(( now - $(mtime "$APP_DIR/cleared-checked") )) -lt 600 ]; then return 0; fi
    touch "$APP_DIR/cleared-checked"
    "$RCLONE" lsf "$DEST" --files-only --contimeout 15s --timeout 60s 2>/dev/null | grep '^Copied - ' > "$APP_DIR/copied" || return 0
    while IFS= read -r f; do
        is_video "$f" || continue
        if "$RCLONE" deletefile "$DEST/$f" --drive-use-trash=false --contimeout 15s --timeout 60s >/dev/null 2>&1; then
            log "Deleted \"$f\" from this Google Drive: Brandon's PC has its own copy."
            n=$((n + 1))
        fi
    done < "$APP_DIR/copied"
    if [ "$n" -gt 0 ]; then STATUS_NOW=1; fi
    return 0
}

follow_live_studio
while IFS= read -r f; do take_if_finished "$f" since; done < <(recordings)
if [ -s "$FOLLOW" ]; then
    : > "$FOLLOW.next"
    while IFS= read -r f; do
        [ -e "$f" ] || continue                          # gone: LIVE Studio moved it on, or someone did
        take_if_finished "$f" || echo "$f" >> "$FOLLOW.next"
    done < "$FOLLOW"
    mv -f "$FOLLOW.next" "$FOLLOW"
fi
rescue_moved
clear_copied

pending() { find "$READY" -type f ! -name '.*' 2>/dev/null; }
label() { pending | while IFS= read -r f; do basename "$f"; done | paste -sd ',' - | sed 's/,/, /g'; }
waiting=$(pending | grep -c . || true)
echo "$waiting" > "$APP_DIR/waiting-count"
if [ "$waiting" -eq 0 ]; then
    if recording_now; then NOW_LINE="A live is on: nothing waits to upload"; BUSY=1; fi
    status_if_due; exit 0
fi
LIVE=""
if recording_now; then
    if [ "$LIVE_UPLOAD" != on ]; then   # a live is on: leave the internet to the stream
        now_live "$waiting"
        if [ ! -f "$APP_DIR/paused" ]; then
            log "A live is recording: $waiting upload(s) wait until it stops, so the stream keeps all the internet."
            touch "$APP_DIR/paused"; STATUS_NOW=1
        fi
        status_if_due; exit 0
    fi
    LIVE=1; BUSY=1   # a live is on: upload slowly, watching the line (below)
fi
if [ -f "$APP_DIR/paused" ]; then
    rm -f "$APP_DIR/paused"
    if [ -n "$LIVE" ]; then log "A live is on: the uploads carry on slowly."; else log "The recording has stopped: uploads carry on."; fi
fi
FILES_LABEL=$(label)

# Show the page when a live has just finished, and once after each restart while uploads are waiting.
# Never during a live: nothing pops up in front of the presenters.
if [ -z "$LIVE" ] && { [ "$finished" -gt 0 ] || [ "$(cat "$APP_DIR/page-opened-boot" 2>/dev/null)" != "$(boot_id)" ]; }; then
    status_preparing
    open_page
fi

# Never overwrite a recording already in Google Drive: a clash gets " (2)", " (3)" and so on.
existing=$("$RCLONE" lsf "$DEST" --files-only --contimeout 15s --timeout 30s 2>/dev/null) ||
    { "$RCLONE" mkdir "$DEST" --contimeout 15s --timeout 30s >/dev/null 2>&1 &&
      existing=$("$RCLONE" lsf "$DEST" --files-only --contimeout 15s --timeout 30s 2>/dev/null); } ||
    { log "Google Drive is not reachable; trying again in a minute."; status_retry 0; NOW_LINE="Waiting for the internet"; status_if_due; exit 0; }
taken() { printf '%s\n' "$existing" | grep -Fxq -- "$1"; }
for f in "$READY"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if taken "$base"; then
        stem="${base%.*}"; ext="${base##*.}"; n=2
        while taken "$stem ($n).$ext" || [ -e "$READY/$stem ($n).$ext" ]; do n=$((n + 1)); done
        mv -n "$f" "$READY/$stem ($n).$ext" && base="$stem ($n).$ext"
    fi
    existing="$existing
$base"
done
waiting=$(pending | grep -c . || true)
FILES_LABEL=$(label)

# Only what fits in Google Drive, oldest first, one at a time.
free=""
if is_remote; then
    free=$("$RCLONE" about "$REMOTE:" --json --contimeout 15s --timeout 30s 2>/dev/null | tr -d ' \n' |
           sed -nE 's/.*"free":([0-9]+).*/\1/p')
fi
budget=${free:-0}
: > "$APP_DIR/to-upload"
total=0; count=0
while IFS= read -r f; do
    size=$(fsize "$f")
    if [ -z "$free" ] || [ $(( size + DRIVE_MARGIN_MB * 1048576 )) -le "$budget" ]; then
        printf '%s\n' "${f#"$READY"/}" >> "$APP_DIR/to-upload"
        budget=$(( budget - size )); total=$(( total + size )); count=$(( count + 1 ))
        if [ -n "$LIVE" ]; then break; fi   # during a live, one at a time
    fi
done < <(pending | sort)
if [ "$count" -eq 0 ]; then
    msg="Google Drive is full ($(( ${free:-0} / 1048576 )) MB free): $waiting recording(s) wait on this Mac until there is room."
    if [ "$(cat "$APP_DIR/full-noted" 2>/dev/null)" != "$msg" ]; then log "$msg"; echo "$msg" > "$APP_DIR/full-noted"; fi
    pct=0
    status_full
    now_full "$waiting"
    status_if_due
    exit 0
fi
rm -f "$APP_DIR/full-noted"
if [ -z "$LIVE" ] && [ "$count" -lt "$waiting" ]; then log "Google Drive has room for $count of the $waiting waiting; the rest go once there is space."; fi
PROGRESS="$APP_DIR/upload-progress.log"
: > "$PROGRESS"
args=(move "$READY" "$DEST" --files-from "$APP_DIR/to-upload" --transfers 1 --retries 3 --low-level-retries 20
      --stats 2s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file "$PROGRESS"
      --rc --rc-addr 127.0.0.1:0)   # its remote control: local only, and file actions need a password it hasn't got
guard=""
if [ -n "$LIVE" ]; then
    measure_line; base=$LAT   # the baseline: the line's delay with the stream on, while this sends nothing
    cap=$(cap_min); limit=$(ceiling_kbit)   # it starts at the minimum and climbs to the ceiling while the stream is fine
    if [ -n "$base" ]; then
        guard=1
        log "A live is on: uploading $(live_name "$(head -n 1 "$APP_DIR/to-upload" | sed 's#.*/##')") at $(mbit_of "$cap") Mbit/s, up to $(mbit_of "$limit")."
        log "The line's delay is ${base} ms (measured while not uploading)."
    else
        log "A live is on: uploading at $(mbit_of "$cap") Mbit/s. (Pings get no answer here, so it can't watch the line, and stays at that.)"
    fi
    args+=(--bwlimit "$(rate_of "$cap")")
    mode=live
else
    log "Uploading $count file(s), $(( total / 1048576 )) MB, to $DEST"
    if [ -n "$BWLIMIT" ]; then args+=(--bwlimit "$BWLIMIT"); fi
    mode=full
fi
full_only=$([ "$mode" = full ] && echo 1)   # measure the line's speed only from a whole upload at full speed
started=$(date +%s)

"$RCLONE" "${args[@]}" &
rclone_pid=$!
if command -v caffeinate >/dev/null 2>&1; then caffeinate -ims -w "$rclone_pid" & fi   # no sleeping mid-upload
stop_upload() { kill "$rclone_pid" 2>/dev/null; kill -CONT "$rclone_pid" 2>/dev/null; wait "$rclone_pid" 2>/dev/null; }
held=""        # set while the upload is stopped to protect the stream (until this time)
set_cap() {    # kbit/s why
    if rc_bwlimit "$(rate_of "$1")"; then cap=$1; log "Upload speed during the live: $(mbit_of "$cap") Mbit/s ($2)."; return 0; fi
    return 1
}
hold() {       # stop sending, for LIVE_PAUSE_SECONDS
    rc_bwlimit "$(rate_of "$LIVE_UPLOAD_FLOOR_KBIT")" || true   # so it starts again gently
    kill -STOP "$rclone_pid" 2>/dev/null
    held=$(( $(date +%s) + LIVE_PAUSE_SECONDS ))
    log "Upload stopped for $(( LIVE_PAUSE_SECONDS / 60 )) minutes to protect the stream ($1)."
}
pct=0
ticks=0
paused=""
restart=""
relaunch=""
status_pid=""
status_tried=0
checked=$(date +%s); good_since=$checked; bad=0
while kill -0 "$rclone_pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    now_s=$(date +%s)
    if [ $((ticks % 15)) -eq 0 ]; then   # a new version takes over now, not after a long upload ...
        UPDATED=""
        update_if_due
        if [ -n "$UPDATED" ]; then
            if [ "$mode" = full ]; then stop_upload; restart=1; break; fi
            # ... but not during a live: starting a slow upload again from the beginning would cost hours
            log "The new version takes over after this upload (a live is on, so it is not started again)."
        fi
    fi
    if [ $((ticks % 8)) -eq 0 ]; then
        if [ "$mode" = full ] && recording_now; then   # a live has started
            full_only=""
            if [ "$LIVE_UPLOAD" = on ] && set_cap "$(cap_min)" "a live started"; then   # (rclone answers only while running)
                kill -STOP "$rclone_pid" 2>/dev/null; measure_line; kill -CONT "$rclone_pid" 2>/dev/null
                base=$LAT; guard=$([ -n "$base" ] && echo 1); limit=$(ceiling_kbit)
                log "The line's delay is ${base:-unknown} ms (measured while not uploading)."
                mode=live; BUSY=1; checked=$(date +%s); good_since=$checked; bad=0
            fi
            if [ "$mode" = full ]; then   # it can't slow down: stop, and carry on after the live (or slowly next minute)
                stop_upload; paused=1; break
            fi
        elif [ "$mode" = live ] && ! recording_now; then   # the live has ended: full speed at once
            kill -CONT "$rclone_pid" 2>/dev/null; held=""
            if rc_bwlimit "$(full_rate)"; then
                mode=full
                log "The live has ended: uploading at full speed."
            else
                stop_upload; relaunch=1; break
            fi
        fi
    fi
    if [ -n "$held" ]; then
        if [ "$now_s" -ge "$held" ]; then   # try again, at the minimum
            measure_line; base=${LAT:-$base}   # the only time the baseline is measured again: nothing is being sent
            kill -CONT "$rclone_pid" 2>/dev/null; held=""   # it carries on gently (see hold), then the minimum
            if rc_bwlimit "$(rate_of "$(cap_min)")"; then cap=$(cap_min); fi
            log "The line's delay is ${LAT:-unknown} ms (measured while not uploading)."
            log "Carrying on with the upload at $(mbit_of "$cap") Mbit/s."
            checked=$(date +%s); good_since=$checked; bad=0
        else
            status_guarded $(( (held - now_s + 59) / 60 ))
        fi
    elif [ "$mode" = live ] && [ -n "$guard" ] &&
         [ $(( now_s - checked )) -ge "$([ "$cap" -gt 4000 ] && echo "$LIVE_GUARD_FAST_EVERY" || echo "$LIVE_GUARD_EVERY")" ]; then
        measure_line; checked=$(date +%s)
        if [ -z "$LAT" ] || [ $(( LAT - base )) -ge "$LIVE_GUARD_MS" ] || [ "$LOSS" -gt "$LIVE_GUARD_LOSS" ]; then
            why="delay ${LAT:-unknown} ms against ${base} ms, ${LOSS}% of pings lost"
            bad=$((bad + 1)); good_since=$checked
            low=$(( cap * 4 / 5 )); if [ "$low" -lt "$(cap_min)" ]; then low=$(cap_min); fi
            if [ "$low" -lt "$limit" ]; then limit=$low; fi   # stay below where the trouble began, for a while
            if [ "$bad" -eq 1 ] && [ $(( cap / 2 )) -ge "$LIVE_UPLOAD_FLOOR_KBIT" ] && set_cap $(( cap / 2 )) "halved: $why"; then :
            elif [ "$bad" -eq 2 ] && [ "$cap" -gt "$(cap_min)" ] && set_cap "$(cap_min)" "back to the minimum: $why"; then :
            else
                hold "$why"; status_guarded $(( (LIVE_PAUSE_SECONDS + 59) / 60 ))
            fi
        else
            bad=0
            top=$(ceiling_kbit)
            if [ "$limit" -gt "$top" ]; then limit=$top; fi
            if [ "$limit" -lt "$top" ] && [ $(( checked - good_since )) -ge "$LIVE_RELAX_SECONDS" ]; then limit=$top; fi
            if [ "$cap" -lt "$limit" ] && [ $(( checked - good_since )) -ge "$LIVE_RAMP_SECONDS" ]; then
                up=$(( cap * 5 / 4 )); if [ "$up" -gt "$limit" ]; then up=$limit; fi
                set_cap "$up" "fine for $(( checked - good_since )) s, ceiling $(mbit_of "$limit")" || true
                good_since=$checked
            fi
        fi
    fi
    line=$(grep -E ' / .*[0-9]+%' "$PROGRESS" 2>/dev/null | tail -n 1)
    if [ -z "$held" ] && [ -n "$line" ]; then
        pct=$(printf '%s' "$line" | grep -oE '[0-9]+%' | tail -n 1 | tr -d '%')
        sizes=$(printf '%s' "$line" | sed -nE 's#.* ([0-9.]+ [KMGTP]?i?B) / ([0-9.]+ [KMGTP]?i?B),.*#\1 / \2#p')
        eta=$(printf '%s' "$line" | sed -nE 's/.*ETA ([^ ]+).*/\1/p')
        if [ -n "$pct" ] && [ -n "$sizes" ]; then
            if [ "$mode" = live ]; then status_slow "$pct" "$sizes"; else status_uploading "$pct" "$sizes" "$eta"; fi
        fi
    fi
    # The note in Drive, mid-upload, every 5 minutes: in the background, so this loop is not held up.
    if [ -n "$NOW_LINE" ]; then
        t=$(date +%s)
        if [ $(( t - $(mtime "$APP_DIR/status-sent" 2>/dev/null || echo 0) )) -ge "$STATUS_BUSY_EVERY" ] &&
           [ $(( t - status_tried )) -ge "$STATUS_BUSY_EVERY" ] &&
           { [ -z "$status_pid" ] || ! kill -0 "$status_pid" 2>/dev/null; }; then
            status_tried=$t
            send_status >/dev/null 2>&1 &
            status_pid=$!
        fi
    fi
    sleep 2
done
left=$(pending | grep -c . || true)
if [ -n "$restart" ]; then
    log "Updated mid-upload: the upload starts again with the new version in a minute."
    status_preparing
    NOW_LINE="Uploading again in a minute, with the new version"
elif [ -n "$relaunch" ]; then
    log "The live has ended: the upload starts again at full speed in a minute."
    status_preparing
    NOW_LINE="Uploading again in a minute, at full speed"
elif [ -n "$paused" ]; then
    if [ "$LIVE_UPLOAD" = on ]; then
        log "A live started, so the upload stopped. It carries on slowly in a minute."
    else
        log "A live started, so the upload stopped. It carries on by itself once the recording stops."
        touch "$APP_DIR/paused"
    fi
    status_paused
    now_live "$left"
elif wait "$rclone_pid"; then
    log "Uploaded to $DEST"
    secs=$(( $(date +%s) - started ))
    if [ -n "$full_only" ] && [ "$total" -ge $(( 50 * 1048576 )) ] && [ "$secs" -ge 20 ]; then   # the line's speed
        echo $(( total * 8 / 1000 / secs )) >> "$APP_DIR/line-speeds"
        tail -n 5 "$APP_DIR/line-speeds" > "$APP_DIR/line-speeds.new"; mv -f "$APP_DIR/line-speeds.new" "$APP_DIR/line-speeds"
        log "The line's upload speed was $(mbit_of $(( total * 8 / 1000 / secs ))) Mbit/s (the line: $(line_report); so up to $(mbit_of "$(ceiling_kbit)") during lives)."
    fi
    status_done
    if [ "$mode" = full ]; then notify "The live recording is in Google Drive. You can turn the Mac off."; fi
    NOW_LINE="Nothing to upload"
    if [ "$mode" = live ] && [ "$left" -gt 0 ]; then NOW_LINE="A live is on: $(plural "$left" "upload waits" "uploads wait"), the next goes slowly in a minute"
    elif [ "$left" -gt 0 ]; then now_full "$left"; fi   # only what fitted went up
else
    grep -vE ' / .*[0-9]+%' "$PROGRESS" | tail -n 5 >> "$LOG"
    if grep -qiE 'storageQuotaExceeded|quota has been exceeded|quotaExceeded' "$PROGRESS"; then
        log "Google Drive is full: it stays in \"Ready to upload\" and is tried again in a minute."
        status_full
        now_full "$left"
    else
        log "Upload failed; it stays in \"Ready to upload\" and is tried again in a minute."
        status_retry "${pct:-0}"
        NOW_LINE="Waiting for the internet"
    fi
fi
if [ -n "$status_pid" ]; then wait "$status_pid" 2>/dev/null; fi   # never two notes going up at once
STATUS_NOW=1
status_if_due
