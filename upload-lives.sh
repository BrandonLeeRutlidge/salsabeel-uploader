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
# - The cloud (clipline) takes each live, then renames the original here "Copied - ..." (Brandon's PC did, before 13 Nov).
#   Every 10 minutes this deletes those for good (only files it uploaded itself), so this Drive never fills.
#   If it is full anyway, the lives wait on this Mac and the status page says so.
# - A short recording (under MIN_LIVE_MB, or under MIN_LIVE_SECONDS from start to stop) is a test, not a
#   live: it goes to "Uploader checks/Short recordings" in Drive, where the cloud never makes clips of it.
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
PARTS_UPLOAD=off               # on: a live goes up in parts (Parts/<name>/part-0001...), so a stop costs one part at most.
PART_MB=250                    #   part size at full speed ...
PART_LIVE_MB=100               #   ... and during a live
PARTS_TPS=2                    #   Drive calls a second while sending a part, at most
PARTS_CHUNK=32M                #   the piece size within a part (fewer calls than rclone's 8M)
PARTS_MIN_MB=300               #   smaller recordings go up whole
LINE_SAMPLE_MIN_MB=50          # a line-speed reading needs at least this much sent at full speed ...
LINE_SAMPLE_MIN_SECONDS=60     # ... over at least this long
LINE_SAMPLE_EVERY=600          # and one every 10 minutes at full speed, so a long upload cut short still gives one
RATE_WAIT_MIN=5                # Google Drive says "slow down" (rate limit): wait this many minutes before trying again,
RATE_WAIT_MAX=60               #   twice as long each time in a row, up to this; a good upload resets it
CLEAR_EVERY=120                # how often it looks for lives the cloud has taken (every minute while Drive is full)
PING_HOSTS="${SALSABEEL_UPLOADER_PING_HOSTS:-1.1.1.1 8.8.8.8}"
PING="${SALSABEEL_UPLOADER_PING:-ping}"
STATUS_IDLE_EVERY=1800   # the status note: every 30 minutes when nothing is happening,
STATUS_BUSY_EVERY=300    # every 5 while something is (an upload, a live, Drive full)
STATUS_EVERY=$STATUS_IDLE_EVERY
CHECKS_FOLDER="Uploader checks"
# "Who are you?": when a live starts, a button per presenter; one click saves it (on this Mac's screen only).
# The names come from "Uploader checks/Presenters.txt" in Drive (the cloud fills it; never from the update repo).
# The answer goes next to the live in Drive as "<recording>.presenters.txt", one name per line.
PRESENTERS_ASK=on
PRESENTERS_WAIT="${SALSABEEL_UPLOADER_ASK_WAIT:-600}"   # the list closes by itself after this long
PRESENTERS_CHIME=on            # a soft chime when "Clock in" shows, again every PRESENTERS_CHIME_EVERY seconds until a tap
PRESENTERS_CHIME_EVERY="${SALSABEEL_UPLOADER_CHIME_EVERY:-60}"
PRESENTERS_CHIME_SOUND=/System/Library/Sounds/Glass.aiff   # macOS's own, about a second long
PRESENTERS_CHIME_VOLUME=0.3    # soft (0 to 1): in case LIVE Studio picks up the Mac's own sound
PRESENTERS_EVERY=600           # how often it reads the names again
ASK="${SALSABEEL_UPLOADER_ASK:-}"   # (the self-test: a pretend list)
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
for f in config.sh status-page.html VERSION self-test.command show-log.command uninstall.command google-app presenters.txt; do
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
status_slowdown() { write_status retry "Google Drive said slow down" "Waiting a few minutes" "Google Drive asked this Mac to slow down for a while. Nothing is wrong with the internet or the live: it tries again by itself at $1. Leave the Mac on." "${pct:-0}" "Next try at $1" "Slowing down · Salsabeel"; }
status_retry() { write_status retry "Not uploaded yet" "Waiting for the internet" "Google Drive could not be reached. It tries again by itself every minute, so leave the Mac on and online." "${1:-0}" "Next try in about a minute" "Waiting · Salsabeel"; }

# --- "Who are you?" window ----------------------------------------------------------------------------
# The same look as the status page (its styles and logo): "Who are you?" with a big tile per name. One click
# saves that name, then the page says "Thanks for clocking in, <name>! Enjoy your shift." for 3 seconds and the
# window closes. It is a web page in a window (JavaScript for macOS, WebKit): no extra permissions. A click sets the
# page's title to "picked:<name>", which the window's own loop reads; the name is written out before anything else.
# If the page won't open, a plain list is used instead. (SALSABEEL_WHO_TEST_PICK clicks a name by itself: a check.)
html_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
WHO_COLS=1; WHO_W=460; WHO_H=300
who_page() {   # names...: writes $APP_DIR/who.html from the status page's own look; sets WHO_W and WHO_H
    local f="$APP_DIR/who.html" name rows
    [ -f "$TEMPLATE" ] && grep -q 'class="brand"' "$TEMPLATE" || return 1
    WHO_COLS=1; WHO_W=560   # big, so nobody can miss it (Brandon, 24 Nov)
    if [ $# -gt 6 ]; then WHO_COLS=3; WHO_W=960; elif [ $# -gt 3 ]; then WHO_COLS=2; WHO_W=760; fi
    rows=$(( ($# + WHO_COLS - 1) / WHO_COLS )); WHO_H=$(( 330 + rows * 92 )); if [ "$WHO_H" -lt 440 ]; then WHO_H=440; fi
    {
        printf '<!DOCTYPE html>\n<html lang="en-GB">\n<head>\n<meta charset="utf-8">\n<title>Salsabeel: clock in</title>\n'
        sed -n '/<style>/,/<\/style>/p' "$TEMPLATE"
        cat <<CSS
<style>
  body { padding: 20px; user-select: none; -webkit-user-select: none; cursor: default; }
  .card { max-width: none; }
  .grid { display: grid; grid-template-columns: repeat($WHO_COLS, 1fr); gap: 14px; margin-top: 22px; }
  .tile { font: inherit; font-size: 28px; font-weight: 700; color: var(--text); background: #232327;
    border: 2px solid var(--line); border-radius: 16px; padding: 22px 10px; cursor: pointer; }
  #who h1 { font-size: 38px; }
  .tile:hover { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(255,45,111,.25), 0 0 18px rgba(255,45,111,.35); }
  .tile:active { background: rgba(255,45,111,.18); }
  #thanks { display: none; }
  .picked #who { display: none; }
  .picked #thanks { display: block; }
  #thanks .msg { margin-bottom: 4px; }
  .sub { font-size: 19px; color: var(--muted); margin: -4px 0 0; }
</style>
</head>
<body>
  <div class="card">
CSS
        grep 'class="brand"' "$TEMPLATE"   # the logo, and "LIVE UPLOADER" as on the status window
        printf '    <div id="who">\n      <div class="state"><span class="dot"></span>Live now</div>\n      <h1>Clock in</h1>\n      <p class="sub">Tap your name.</p>\n      <div class="grid">\n'
        for name in "$@"; do printf '        <button class="tile">%s</button>\n' "$(html_esc "$name")"; done
        printf '      </div>\n    </div>\n'
        printf '    <div id="thanks" class="done">\n      <div class="state"><span class="dot"></span>Clocked in</div>\n'
        printf '      <h1>Thanks for clocking in, <span id="name"></span>!</h1>\n      <p class="msg">Enjoy your shift.</p>\n    </div>\n'
        printf '  </div>\n<script>\n'
        printf '  var done = false;\n'
        printf '  function pick(n) { if (done) return; done = true; document.getElementById("name").textContent = n;\n'
        printf '    document.body.classList.add("picked"); document.title = "picked:" + n; }\n'
        printf '  document.querySelectorAll(".tile").forEach(function (b) { b.addEventListener("click", function () { pick(b.textContent); }); });\n'
        if [ -n "${SALSABEEL_WHO_TEST_PICK:-}" ]; then
            printf '  var seen = 0; setInterval(function () { if (document.visibilityState !== "visible") return; if (!seen) seen = Date.now();\n'
            printf '    if (Date.now() - seen > 2500) document.querySelectorAll(".tile").forEach(function (b) { if (b.textContent === "%s") b.click(); }); }, 250);\n' "$(html_esc "$SALSABEEL_WHO_TEST_PICK")"
        fi
        printf '</script>\n</body>\n</html>\n'
    } > "$f.tmp" && mv -f "$f.tmp" "$f"
}
WHO_WINDOW='ObjC.import("Cocoa"); ObjC.import("WebKit");
function run(argv) {
  var page = argv[0], W = Number(argv[1]), H = Number(argv[2]);
  var trigger = argv[3] || "";   // standby: load now, hidden; show the moment this file appears (instant)
  var fm = $.NSFileManager.defaultManager;
  var app = $.NSApplication.sharedApplication, picked = "", closed = false, shown = 0, snapped = {};
  var testSnap = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("SALSABEEL_WHO_TEST_SNAP")) || "";
  app.setActivationPolicy(1);   // no Dock icon
  app.finishLaunching;
  ObjC.registerSubclass({ name: "SalsabeelWho", protocols: ["NSWindowDelegate"], methods: {
    "windowWillClose:": { types: ["void", ["id"]], implementation: function (n) { closed = true; } } } });
  function pump(seconds) {   // answer the window for up to this long (no beachball)
    var ev = app.nextEventMatchingMaskUntilDateInModeDequeue($.NSEventMaskAny, $.NSDate.dateWithTimeIntervalSinceNow(seconds), $.NSDefaultRunLoopMode, true);
    if (ev && !ev.isNil()) app.sendEvent(ev);
  }
  // One window on every screen (an external monitor may be the one they look at); a tap on any of them counts
  var screens = $.NSScreen.screens, nScreens = Number(screens.count), wins = [], wvs = [];
  var url = $.NSURL.fileURLWithPath(page), info = page.replace(/[^\/]*$/, "") + "shown.txt";
  for (var i = 0; i < Math.max(1, nScreens); i++) {
    var w1 = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, W, H), 1 | 2, 2, false);
    w1.title = "Salsabeel"; w1.releasedWhenClosed = false; w1.delegate = $.SalsabeelWho.alloc.init;
    w1.level = 1000;               // above every other window, menus and the Dock (the screen saver level)
    w1.collectionBehavior = 1 | 16 | 256;   // every Space, stays put, and over full-screen apps (like LIVE Studio)
    w1.backgroundColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(14 / 255, 14 / 255, 16 / 255, 1);
    var v1 = $.WKWebView.alloc.initWithFrameConfiguration($.NSMakeRect(0, 0, W, H), $.WKWebViewConfiguration.alloc.init);
    w1.contentView = v1;
    v1.loadFileURLAllowingReadAccessToURL(url, url.URLByDeletingLastPathComponent);
    wins.push(w1); wvs.push(v1);
  }
  var win = wins[0], wv = wvs[0];
  function titleOf(v) { var t = v.title; return (t && !t.isNil()) ? ObjC.unwrap(t) : ""; }
  function title() {   // the one that was tapped, if any (then that is the one that shows the thank-you)
    for (var j = 0; j < wvs.length; j++) { var tj = titleOf(wvs[j]); if (tj.indexOf("picked:") === 0) { win = wins[j]; wv = wvs[j]; return tj; } }
    return titleOf(wvs[0]);
  }
  function report() {   // (for the log: did it really show, where, and what was in front)
    var vis = 0, front = "";
    for (var j = 0; j < wins.length; j++) { if (wins[j].isVisible && (Number(wins[j].occlusionState) & 2)) vis++; }
    try { front = ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName) || ""; } catch (e) {}
    $("screens=" + nScreens + " visible=" + vis + " front=" + front + "\n").writeToFileAtomicallyEncodingError(info, true, 4, $());
  }
  function snap(name) {   // (a check on a Mac: a picture of the window)
    if (!testSnap || snapped[name]) return;
    snapped[name] = true;
    try {
      wv.takeSnapshotWithConfigurationCompletionHandler($(), function (img, err) {
        try { $.NSBitmapImageRep.imageRepWithData(img.TIFFRepresentation).representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({})).writeToFileAtomically(testSnap + "/" + name + ".png", true); } catch (e) {}
      });
    } catch (e) { $(String(e)).writeToFileAtomicallyEncodingError(testSnap + "/" + name + ".err", true, 4, $()); }
  }
  var t0 = Date.now(), ready = false, reported = false;
  while (!picked && !closed && (!shown || Date.now() - shown < 900000)) {   // the shell closes it sooner (10 minutes)
    pump(shown || !trigger ? 0.1 : 0.05);
    var t = title();
    if (!ready && wvs.every(function (v) { return titleOf(v).indexOf("Salsabeel") === 0; })) {
      ready = true;
      if (trigger) $("ready").writeToFileAtomicallyEncodingError(trigger + ".ready", true, 4, $());
    }
    if (!shown && ready && (!trigger || fm.fileExistsAtPath(trigger))) {   // centred on every screen, in front of everything
      app.activateIgnoringOtherApps(true);
      for (var k = 0; k < wins.length; k++) {
        var sf = (k < nScreens ? screens.objectAtIndex(k) : $.NSScreen.mainScreen).frame;
        wins[k].setFrameOrigin($.NSMakePoint(sf.origin.x + (sf.size.width - W) / 2, sf.origin.y + (sf.size.height - H) / 2));
        wins[k].makeKeyAndOrderFront(null); wins[k].orderFrontRegardless;
      }
      wins[0].makeKeyWindow;
      shown = Date.now();
    }
    if (shown && !reported && Date.now() - shown > 1500) { reported = true; try { report(); } catch (e) {} }
    if (!ready && Date.now() - t0 > 10000) throw new Error("the page did not open");
    if (shown && testSnap && !snapped["shown"]) {   // (a check: how fast it showed)
      snapped["shown"] = true; $(String(Date.now())).writeToFileAtomicallyEncodingError(testSnap + "/shown-at", true, 4, $());
    }
    if (shown && Date.now() - shown > 1500) snap("1-who");
    if (shown && t.indexOf("picked:") === 0) picked = t.slice(7);
  }
  if (picked) {
    $.NSFileHandle.fileHandleWithStandardOutput.writeData($(picked + "\n").dataUsingEncoding(4));   // the name, first
    wins.forEach(function (w) { if (w !== win) w.orderOut(null); });   // only the tapped one says thank you
    try {
      var end = Date.now() + 3000;
      while (Date.now() < end && !closed) {   // the thank-you, for a fixed 3 seconds, still answering
        pump(0.1);
        if (Date.now() > end - 2000) snap("2-thanks");
      }
    } catch (e) {}
  }
  wins.forEach(function (w) { w.orderOut(null); });
  return "";
}'
who_window() {   # names...: the window (the page is made first; no page, no window: the plain list is used)
    who_page "$@" || return 1
    osascript -l JavaScript -e "$WHO_WINDOW" "$APP_DIR/who.html" "$WHO_W" "$WHO_H"
}
who_list() {   # the plain list, if the window won't open (it needs an OK)
    osascript -e 'on run argv' -e 'activate' \
        -e 'set picked to choose from list argv with title "Salsabeel" with prompt "Clock in: tap your name" OK button name "That’s me" cancel button name "Skip"' \
        -e 'if picked is false then return ""' -e 'return item 1 of picked' -e 'end run' "$@"
}
thanks_note() {   # name: the plain list's thank-you (the window shows its own); never more than 8 seconds
    local p i=0
    if [ -n "${SALSABEEL_UPLOADER_THANKS:-}" ]; then
        "$SALSABEEL_UPLOADER_THANKS" "$1" >/dev/null 2>&1 &
    else
        osascript -e 'on run argv' -e 'try' -e 'activate' \
            -e 'display dialog ("Thanks for clocking in, " & item 1 of argv & "!" & return & "Enjoy your shift.") with title "Salsabeel" buttons {"OK"} default button 1 giving up after 3' \
            -e 'end try' -e 'end run' "$1" >/dev/null 2>&1 &
    fi
    p=$!
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt 8 ]; do sleep 1; i=$((i + 1)); done
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
}
if [ "${1:-}" = "--who" ]; then   # the window on its own (a check): --who name name ...; prints the name clicked
    shift
    TEMPLATE="${SALSABEEL_UPLOADER_TEMPLATE:-$(dirname "$0")/status-page.html}"
    who_window "$@"
    exit $?
fi

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
    if [ -n "${SALSABEEL_UPLOADER_NOTIFY:-}" ]; then "$SALSABEEL_UPLOADER_NOTIFY" "$1"; return 0; fi   # (the self-test)
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
utc_of() { if [ "$(uname)" = "Darwin" ]; then date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; else date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; fi; }
live_presenters() {   # the name(s) clicked for the live on now, comma-separated ("" if none yet)
    local s on
    on=$(cat "$APP_DIR/live-on" 2>/dev/null) || return 0
    for s in "$PRES"/*.src; do
        if [ "$(cat "$s")" = "$on" ] && [ -s "${s%.src}.names" ]; then paste -sd ',' "${s%.src}.names" | sed 's/,/, /g'; return 0; fi
    done
}
live_studio_sound() {   # LIVE Studio's sound settings, from its own files (once an hour): does the Mac's sound go out?
    local c="$APP_DIR/live-studio-sound" spot f
    if [ -f "$c" ] && [ $(( $(date +%s) - $(mtime "$c") )) -lt 3600 ]; then cat "$c"; return 0; fi
    for spot in "$HOME/Library/Application Support" "$HOME/Library/Preferences"; do
        find "$spot" -maxdepth 1 \( -iname '*tiktok*' -o -iname '*live*studio*' \) 2>/dev/null
    done | while IFS= read -r spot; do
        find "$spot" -maxdepth 6 -type f -size -5M 2>/dev/null | head -n 300 | while IFS= read -r f; do
            case "$f" in
                *.plist) if command -v plutil >/dev/null 2>&1; then plutil -convert json -o - "$f" 2>/dev/null; fi ;;
                *.json|*.ini|*.cfg|*.conf|*.config|*.txt|*.xml) LC_ALL=C cat "$f" 2>/dev/null ;;
            esac
        done
    done | LC_ALL=C grep -a -o -i -E '"[A-Za-z_]*(audio|sound|mic|speaker|desktop|system)[A-Za-z_]*" *: *("[^"]{0,40}"|-?[0-9.]+|true|false)' 2>/dev/null |
        LC_ALL=C sort -u | head -n 12 | paste -sd ';' - | sed 's/;/; /g' | cut -c1-400 > "$c.new"
    if [ ! -s "$c.new" ]; then echo "(no sound settings found in LIVE Studio's files)" > "$c.new"; fi
    mv -f "$c.new" "$c"; cat "$c"
}
send_status() {
    local note="$APP_DIR/Mac status.txt" drive mac waiting=0 ready=0 f who
    rm -f "$APP_DIR/status-due"   # (set again below if this one doesn't go)
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
        if [ -f "$APP_DIR/live-on" ]; then   # for the live screen: sent within a minute of each change
            echo "Live:               on since $(utc_of "$(mtime "$APP_DIR/live-on")")"
            who=$(live_presenters); if [ -n "$who" ]; then echo "Presenters:         $who"; fi
        else
            echo "Live:               off"
        fi
        if [ -f "$APP_DIR/last-sleep" ] && [ $(( $(date +%s) - $(mtime "$APP_DIR/last-sleep") )) -lt 86400 ]; then
            echo "Asleep:             $(cat "$APP_DIR/last-sleep")"
        fi
        echo "Line:               $(line_report)"
        echo "LIVE Studio sound:  $(live_studio_sound)"
        echo "Mac:                $mac"
        echo "Version:            $(cat "$APP_DIR/VERSION" 2>/dev/null || echo unknown)"
        echo "Recording folder:   $WATCH_DIR"
        echo "  videos in it:     $waiting (recording, or stopped less than ${QUIET_MINUTES} minutes ago)"
        echo "Waiting to upload:  $ready"
        if [ -n "${IN_DRIVE+x}" ]; then echo "In Google Drive, not yet taken by the cloud: $IN_DRIVE"; fi
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
    touch "$APP_DIR/status-due"
    return 1
}
status_if_due() {
    local sent="$APP_DIR/status-sent"
    STATUS_EVERY=$STATUS_IDLE_EVERY
    if [ -n "$BUSY" ] || [ -f "$APP_DIR/paused" ] || [ -f "$APP_DIR/full-noted" ] ||
       [ -n "$(find "$READY" -type f ! -name '.*' 2>/dev/null | head -n 1)" ]; then
        STATUS_EVERY=$STATUS_BUSY_EVERY
    fi
    if [ "$STATUS_NOW" = 1 ] || [ -f "$APP_DIR/status-due" ] || [ ! -f "$sent" ] || [ $(( $(date +%s) - $(mtime "$sent") )) -ge "$STATUS_EVERY" ]; then
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
    for f in upload-lives.sh status-page.html config.sh VERSION self-test.command show-log.command uninstall.command google-app presenters.txt; do
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
line_known_kbit() {   # the line's upload speed: the best of the last 5 full-speed readings; "" if none yet
    tail -n 5 "$APP_DIR/line-speeds" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n 1
}
to_bytes() { awk -v v="${1% *}" -v u="${1#* }" 'BEGIN { m = 1; if (u ~ /^K/) m = 1024; else if (u ~ /^M/) m = 1048576;
    else if (u ~ /^G/) m = 1073741824; else if (u ~ /^T/) m = 1099511627776; printf "%.0f", v * m }'; }
line_sample() {   # bytes seconds: a reading of the line, from time spent at full speed (1 to 1000 Mbit/s, or ignored)
    local k
    [ "$2" -ge "$LINE_SAMPLE_MIN_SECONDS" ] && [ "$1" -ge $(( LINE_SAMPLE_MIN_MB * 1048576 )) ] || return 0
    k=$(( $1 * 8 / 1000 / $2 ))
    if [ "$k" -lt 1000 ] || [ "$k" -gt 1000000 ]; then log "Ignored an odd line-speed reading: $(mbit_of "$k") Mbit/s."; return 0; fi
    echo "$k" >> "$APP_DIR/line-speeds"
    tail -n 5 "$APP_DIR/line-speeds" > "$APP_DIR/line-speeds.new"; mv -f "$APP_DIR/line-speeds.new" "$APP_DIR/line-speeds"
    log "The line's upload speed was $(mbit_of "$k") Mbit/s (the line: $(line_report); so up to $(mbit_of "$(ceiling_kbit)") during lives)."
}
line_report() {   # "87 Mbit/s up (measured 20:40, last 5 uploads)" or "not measured yet"
    local l n
    l=$(line_known_kbit)
    if [ -z "$l" ]; then echo "not measured yet"; return; fi
    n=$(tail -n 5 "$APP_DIR/line-speeds" | grep -cE '^[0-9]+$')
    echo "$(awk -v k="$l" 'BEGIN { if (k >= 10000) printf "%.0f", k / 1000; else printf "%.1f", k / 1000 }') Mbit/s up (measured $(clock_of "$(mtime "$APP_DIR/line-speeds")" '%H:%M'), best of the last $(plural "$n" reading readings))"
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
rc_port() {   # a free local port for rclone's remote control (so its address is known, not read from its log)
    local p
    for p in 5590 5591 5592 5593 5594 5595 5596 5597 5598 5599; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
    done
    echo 0
}
rc_bwlimit() {   # change rclone's speed while it runs (its remote control, local only, file actions refused); 3 tries
    local i
    if [ -z "$RC_URL" ]; then
        RC_URL=$(sed -nE 's#.*Serving remote control on (http://127\.0\.0\.1:[1-9][0-9]*/).*#\1#p' "$PROGRESS" 2>/dev/null | head -n 1)
    fi
    local err url logged
    logged=$(sed -nE 's#.*Serving remote control on (http://[^ ]+/).*#\1#p' "$PROGRESS" 2>/dev/null | head -n 1)
    for i in 1 2 3; do
        for url in $RC_URL $logged; do   # the address it was given, or the one rclone says it serves on
            if err=$("$RCLONE" rc --url "$url" --user salsabeel --pass "$RC_PASS" --timeout 10s core/bwlimit "rate=$1" 2>&1); then
                RC_URL=$url; return 0
            fi
        done
        sleep 1
    done
    if [ "$(cat "$APP_DIR/rc-failed" 2>/dev/null)" != "$rclone_pid" ]; then   # why, once per upload (for Brandon)
        echo "$rclone_pid" > "$APP_DIR/rc-failed"
        log "Could not change rclone's speed (at ${RC_URL:-no address}${logged:+, or $logged}): $(printf '%s' "$err" | grep -v '^$' | tail -n 1)."
        log "  rclone's own words: $(grep -iE 'remote control|rc server|listen' "$PROGRESS" 2>/dev/null | tail -n 1)"
    fi
    return 1
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
if [ "${1:-}" != --clock-in-helper ]; then   # (the "Clock in" helper runs alongside, below)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then exit 0; fi
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
fi
# "Fix Salsabeel uploader" is switching the Google sign-in: start nothing until it's done (at most 30 minutes)
HELPER_RUN=""; if [ "${1:-}" = --clock-in-helper ]; then HELPER_RUN=1; fi
if [ -z "$HELPER_RUN" ]; then
    if [ -f "$APP_DIR/fixer-hold" ] && [ $(( $(date +%s) - $(mtime "$APP_DIR/fixer-hold") )) -lt 1800 ]; then exit 0; fi
    update_if_due   # (only the uploader updates; the helper picks the new version up when it next starts)
fi

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
            presenters_named "$f" "$target" short
        else
            log "Recording finished: \"${f#"$WATCH_DIR"/}\" is now \"$(basename "$target")\""
            presenters_named "$f" "$target"
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
keep_open_note() {   # a live has ended with uploads left: ask them (once, on screen) to keep the laptop open
    local b=0 f l m
    while IFS= read -r f; do b=$(( b + $(fsize "$f") )); done < <(find "$READY" -type f ! -name '.*' 2>/dev/null)
    [ "$b" -gt 0 ] || return 0
    l=$(line_known_kbit); l=${l:-10000}
    m=$(( b * 8 / 1000 / l / 60 + 1 ))
    if [ "$m" -ge 90 ]; then m="$(( (m + 30) / 60 )) hours"; else m=$(plural "$m" minute minutes); fi
    notify "Uploading: about $m left. Please keep the laptop open."
    log "Asked them to keep the laptop open: about $m of uploading left."
}
# --- "Who are you?" (who is on this live) ------------------------------------------------------------------------
PRES="$APP_DIR/presenters"   # per live: <id>.src (the file LIVE Studio records to), <id>.names (the answer),
                             # <id>.name (the recording's name in Drive, once it has one)
presenter_names() {   # the names to tick: one per line; blank lines and lines starting # left out
    local f="$APP_DIR/presenters.txt"   # this Mac's copy (never waits on Drive), or the hidden backup of the last list
    if [ ! -f "$f" ]; then f="$BACKUP/presenters.txt"; fi
    [ -f "$f" ] || return 0
    tr -d '\r' < "$f" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        grep -v '^#' | grep -v '^$' || true
}
read_presenters() {   # the names list from Drive (every PRESENTERS_EVERY). The Mac can only see files it made itself,
    local t list n     # so if there is none it makes one (no names in it) for the cloud to fill in.
    [ "$PRESENTERS_ASK" = on ] || return 0
    t=$(date +%s)
    if [ -f "$APP_DIR/presenters-checked" ] && [ $(( t - $(mtime "$APP_DIR/presenters-checked") )) -lt "$PRESENTERS_EVERY" ]; then return 0; fi
    touch "$APP_DIR/presenters-checked"
    list=$("$RCLONE" lsf "$DEST/$CHECKS_FOLDER" --files-only --contimeout 15s --timeout 30s 2>/dev/null) || return 0
    read_google_app "$list"
    if printf '%s\n' "$list" | grep -qxF 'Presenters.txt'; then
        "$RCLONE" cat "$DEST/$CHECKS_FOLDER/Presenters.txt" --contimeout 15s --timeout 30s > "$APP_DIR/presenters.new" 2>/dev/null &&
            [ -s "$APP_DIR/presenters.new" ] || { rm -f "$APP_DIR/presenters.new"; return 0; }
        if ! cmp -s "$APP_DIR/presenters.new" "$APP_DIR/presenters.txt"; then
            mv -f "$APP_DIR/presenters.new" "$APP_DIR/presenters.txt"
            n=$(presenter_names | grep -c . || true)
            log "The presenters list in Drive has $(plural "$n" name names)."
        else
            rm -f "$APP_DIR/presenters.new"
        fi
    elif printf '%s\n' "# Presenters: one name per line. The live uploader asks \"Who are you?\" with these names" \
             "# when a live starts. The cloud keeps this file up to date. Lines starting # are left out." |
         "$RCLONE" rcat "$DEST/$CHECKS_FOLDER/Presenters.txt" --contimeout 15s --timeout 30s >/dev/null 2>&1; then
        log "Made \"$CHECKS_FOLDER/Presenters.txt\" in Drive, for the cloud to fill with the presenters' names."
    fi
}
got_name() {   # base [answer file]: a name has come back? Saved at once (kept even if the window then fails or hangs)
    local base=$1 ans=${2:-$1.answer} n
    [ -s "$ans" ] || return 1
    tr -d '\r' < "$ans" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | awk '!s[$0]++' > "$base.ticked"
    n=$(grep -c . "$base.ticked" || true)
    if [ "$n" -eq 0 ]; then rm -f "$base.ticked"; return 1; fi
    if [ -f "$base.src" ]; then
        mv -f "$base.ticked" "$base.names"; date '+%Y-%m-%d %H:%M:%S' > "$base.at"   # saved on this Mac; Drive gets it whenever it can
        touch "$APP_DIR/status-due"   # the note says who it is within a minute
        log "Who's on this live: $(paste -sd ',' "$base.names" | sed 's/,/, /g') (clicked)."
    else
        rm -f "$base.ticked"
    fi
    return 0
}
THANKS_MAX="${SALSABEEL_UPLOADER_THANKS_MAX:-15}"
chime() {   # a short, soft sound so they look at the screen ("Clock in" is waiting); never held up by it
    [ "$PRESENTERS_CHIME" = on ] || return 0
    if [ -n "${SALSABEEL_UPLOADER_CHIME:-}" ]; then "$SALSABEEL_UPLOADER_CHIME" >/dev/null 2>&1 &
    elif command -v afplay >/dev/null 2>&1; then afplay -v "$PRESENTERS_CHIME_VOLUME" "$PRESENTERS_CHIME_SOUND" >/dev/null 2>&1 &
    fi
}   # once a name is in, the window gets this long to say thanks and close
shown_note() {   # the window's own report (a second after it shows): did it really show, on how many screens, what was in front
    local sc vis fr
    if [ ! -s "$1" ]; then log "\"Clock in\": the window did not say whether it is on screen."; return 0; fi
    sc=$(sed -n 's/.*screens=\([0-9]*\).*/\1/p' "$1"); vis=$(sed -n 's/.*visible=\([0-9]*\).*/\1/p' "$1"); fr=$(sed -n 's/.*front=//p' "$1" | head -n 1)
    if [ "${vis:-0}" -gt 0 ]; then
        log "\"Clock in\" is on screen: visible on $vis of $(plural "${sc:-1}" screen screens) (in front: ${fr:-?})."
    else
        log "\"Clock in\" is NOT visible: macOS says it is covered on all $(plural "${sc:-1}" screen screens) (in front: ${fr:-?})."
    fi
}
ask_window() {   # base names...: on this Mac's screen; the name clicked goes to base.names (none if closed or left)
    local base=$1 pid t=0 st=0 how=window saved="" limit ans adopted="" info="$APP_DIR/shown.txt" told=""
    shift
    ans="$base.answer"
    if [ -n "${ADOPT_STANDBY:-}" ] && standby_ready; then   # the window is loaded and waiting: show it now
        info="$STANDBY/shown.txt"; rm -f "$info"
        touch "$STANDBY/trigger"; pid=$(cat "$STANDBY/pid"); ans="$STANDBY/out"; adopted=1
    elif rm -f "$info" && [ -n "$ASK" ]; then "$ASK" "$@" > "$ans" 2>/dev/null & pid=$!
    else who_window "$@" > "$ans" 2>/dev/null & pid=$!
    fi
    while :; do
        limit=$PRESENTERS_WAIT
        while kill -0 "$pid" 2>/dev/null && [ "$t" -lt "$limit" ]; do
            if [ -z "$saved" ] && [ $(( t % PRESENTERS_CHIME_EVERY )) -eq 1 ]; then chime; fi   # as it shows, then every minute
            sleep 1; t=$((t + 1))
            if [ -z "$told" ] && [ "$how" = window ] && { [ -s "$info" ] || [ "$t" -ge 6 ]; }; then told=1; shown_note "$info"; fi
            if [ -z "$saved" ] && got_name "$base" "$ans"; then saved=1; limit=$(( t + THANKS_MAX )); fi
        done
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; st=timeout
        elif [ -n "$adopted" ]; then if [ "$t" -le 3 ]; then st=1; else st=0; fi   # (not this shell's child: no exit code)
        else wait "$pid"; st=$?; fi
        if [ -z "$saved" ] && got_name "$base" "$ans"; then saved=1; fi
        if [ -n "$saved" ] || [ "$st" = 0 ] || [ "$st" = timeout ] || [ "$how" = list ] || [ "$t" -gt 15 ]; then break; fi
        log "The \"Who are you?\" window would not open (error $st), so it asks with a plain list instead."
        how=list; adopted=""; ans="$base.answer"
        if [ -n "${SALSABEEL_UPLOADER_ASK2:-}" ]; then "$SALSABEEL_UPLOADER_ASK2" "$@" > "$ans" 2>/dev/null &
        else who_list "$@" > "$ans" 2>/dev/null & fi
        pid=$!
    done
    rm -f "$base.answer"
    if [ -n "$adopted" ] || [ -e "$STANDBY/trigger" ]; then rm -f "$STANDBY/out" "$STANDBY/trigger" "$STANDBY/trigger.ready" "$STANDBY/pid"; fi
    if [ -n "$saved" ]; then
        if [ "$how" = list ] && [ -f "$base.names" ]; then thanks_note "$(head -n 1 "$base.names")"; fi
    elif [ "$st" = timeout ]; then
        log "Nobody answered \"Who are you?\", so it closed by itself after $(plural $(( (PRESENTERS_WAIT + 59) / 60 )) minute minutes)."
    else
        log "\"Who are you?\" was closed without a name."
    fi
}
# Our own Google app for rclone (no more sharing rclone's built-in one). The cloud fills "Mac Google app.txt" in Drive
# with its ID and secret; the Mac keeps a copy (readable only by this user) for "Fix Salsabeel uploader", which
# makes the switch (it needs a Google sign-in). Nothing changes on this Mac until the file has both lines.
GOOGLE_APP_FILE="Mac Google app.txt"
read_google_app() {   # the "Uploader checks" listing
    local f="$APP_DIR/google-app"
    if printf '%s\n' "$1" | grep -qxF "$GOOGLE_APP_FILE"; then
        ( umask 077; "$RCLONE" cat "$DEST/$CHECKS_FOLDER/$GOOGLE_APP_FILE" --contimeout 15s --timeout 30s 2>/dev/null |
              tr -d '\r' | grep -E '^client_(id|secret)=[^[:space:]]+$' > "$f.new" ) || true
        if [ "$(grep -c . "$f.new" 2>/dev/null)" = 2 ] && ! cmp -s "$f.new" "$f"; then
            mv -f "$f.new" "$f"; chmod 600 "$f"
            if [ -d "$BACKUP" ]; then cp -p "$f" "$BACKUP/google-app" 2>/dev/null; fi
            log "Our own Google app is ready (from Drive). Running \"Fix Salsabeel uploader\" once switches the sign-in to it."
        else
            rm -f "$f.new"
        fi
    elif printf '%s\n' "# Mac Google app: the cloud fills in client_id= and client_secret= here. Keep it private." |
         "$RCLONE" rcat "$DEST/$CHECKS_FOLDER/$GOOGLE_APP_FILE" --contimeout 15s --timeout 30s >/dev/null 2>&1; then
        log "Made \"$CHECKS_FOLDER/$GOOGLE_APP_FILE\" in Drive, for the cloud to fill in."
    fi
}
# The "Clock in" helper (Brandon, 24 Nov: "it needs to be instant the moment they press the live button"):
# a small background job of its own (launchd, always running) that keeps the window loaded but hidden, looks at
# LIVE Studio's save folder 4 times a second, and shows the window the moment a recording appears. Starting the
# window from cold takes a few seconds; showing a loaded one is instant.
HELPER_LABEL="com.salsabeel.clock-in"
HELPER_PLIST="${SALSABEEL_UPLOADER_HELPER_PLIST:-$HOME/Library/LaunchAgents/$HELPER_LABEL.plist}"
STANDBY="$APP_DIR/standby"
standby_ready() {   # loaded, hidden and not yet shown
    [ -s "$STANDBY/pid" ] && kill -0 "$(cat "$STANDBY/pid")" 2>/dev/null && [ -f "$STANDBY/trigger.ready" ] && [ ! -e "$STANDBY/trigger" ]
}
standby_stop() {
    if [ -s "$STANDBY/pid" ]; then kill "$(cat "$STANDBY/pid")" 2>/dev/null; fi
    rm -f "$STANDBY/pid" "$STANDBY/out" "$STANDBY/trigger" "$STANDBY/trigger.ready" "$STANDBY/names"
}
standby_start() {   # a window, loaded and hidden, for the names in Drive now
    local names=() n
    while IFS= read -r n; do names+=("$n"); done < <(presenter_names)
    [ "${#names[@]}" -gt 0 ] || return 0
    mkdir -p "$STANDBY"; standby_stop
    presenter_names > "$STANDBY/names"
    set -m   # its own process group: it outlives whoever started it
    if [ -n "${SALSABEEL_UPLOADER_STANDBY_CMD:-}" ]; then   # (the self-test: a pretend window)
        "$SALSABEEL_UPLOADER_STANDBY_CMD" "$STANDBY/trigger" "${names[@]}" > "$STANDBY/out" 2>/dev/null </dev/null &
    else
        who_page "${names[@]}" && cp -f "$APP_DIR/who.html" "$STANDBY/who.html" &&
            osascript -l JavaScript -e "$WHO_WINDOW" "$STANDBY/who.html" "$WHO_W" "$WHO_H" "$STANDBY/trigger" \
                > "$STANDBY/out" 2>/dev/null </dev/null &
    fi
    echo $! > "$STANDBY/pid"
    set +m
}
clock_in_helper() {   # the helper's loop (an hour at a time; launchd starts it again, with any new version)
    local end n=0 f
    end=$(( $(date +%s) + ${SALSABEEL_UPLOADER_HELPER_SECONDS:-3600} ))
    mkdir -p "$STANDBY"; touch "$STANDBY/mark"
    while [ "$(date +%s)" -lt "$end" ]; do
        n=$((n + 1))
        if [ "$PRESENTERS_ASK" = on ] && [ ! -f "$APP_DIR/live-on" ] && [ -n "$(presenter_names | head -n 1)" ]; then
            if ! standby_ready && { [ ! -s "$STANDBY/pid" ] || ! kill -0 "$(cat "$STANDBY/pid")" 2>/dev/null ||
                                    ! presenter_names | cmp -s - "$STANDBY/names"; }; then
                if [ ! -e "$STANDBY/trigger" ]; then standby_start; fi
            fi
            # a recording that started since the last look (LIVE Studio writes to it all the time)
            f=$(find "$WATCH_DIR" -maxdepth 3 \( -path "$READY" -o -name '.*' \) -prune -o -type f \
                     \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.flv' \) -newer "$STANDBY/mark" -print 2>/dev/null | head -n 1)
            touch "$STANDBY/mark"
            if [ -n "$f" ]; then recording_now "$f" >/dev/null 2>&1; fi
        fi
        sleep "${SALSABEEL_UPLOADER_HELPER_EVERY:-0.25}"
    done
    if [ ! -e "$STANDBY/trigger" ]; then standby_stop; fi   # a window in use is left to finish
}
helper_plist() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$HELPER_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml "$APP_DIR/upload-lives.sh")</string>
        <string>--clock-in-helper</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
}
ensure_helper() {   # the helper's background job: written and started once (and again if it changes or goes)
    local lc="${SALSABEEL_UPLOADER_LAUNCHCTL:-launchctl}"
    [ "$PRESENTERS_ASK" = on ] || return 0
    command -v "$lc" >/dev/null 2>&1 || [ -n "${SALSABEEL_UPLOADER_HELPER_PLIST:-}" ] || return 0
    if helper_plist | cmp -s - "$HELPER_PLIST"; then return 0; fi
    mkdir -p "$(dirname "$HELPER_PLIST")" && helper_plist > "$HELPER_PLIST.tmp" && mv -f "$HELPER_PLIST.tmp" "$HELPER_PLIST" || return 0
    "$lc" bootout "gui/$(id -u)/$HELPER_LABEL" >/dev/null 2>&1
    if "$lc" bootstrap "gui/$(id -u)" "$HELPER_PLIST" >/dev/null 2>&1 || "$lc" load -w "$HELPER_PLIST" >/dev/null 2>&1; then
        log "Started the \"Clock in\" helper (it shows \"Clock in\" the moment a live starts)."
    fi
}
ask_presenters() {   # a live has started (the file it records to): ask "Who are you?", once per recording
    local s id n how names=()
    [ "$PRESENTERS_ASK" = on ] || return 0
    for s in "$PRES"/*.src; do if [ "$(cat "$s")" = "$1" ]; then return 0; fi; done   # (asked already)
    while IFS= read -r n; do names+=("$n"); done < <(presenter_names)
    if [ "${#names[@]}" -eq 0 ]; then return 0; fi   # no names in Drive yet: nothing to ask
    mkdir -p "$PRES"; id=$(date +%s)
    while [ -e "$PRES/$id.src" ]; do id=$((id + 1)); done
    printf '%s\n' "$1" > "$PRES/$id.src"
    # In the background, in its own process group, so it never holds anything up and outlives this run
    # (launchd ends whatever is left in a run's group when the run ends).
    if standby_ready; then how="shown at once: it was ready"; else how="opened fresh"; fi
    set -m
    ADOPT_STANDBY=1 ask_window "$PRES/$id" "${names[@]}" </dev/null >/dev/null 2>&1 &
    set +m
    log "Asked \"Clock in\" ($how) on this Mac's screen ($(plural "${#names[@]}" name names); it closes by itself after $(plural $(( (PRESENTERS_WAIT + 59) / 60 )) minute minutes))."
}
presenters_named() {   # recording-path new-path [short]: the answer belongs to this name in Drive
    local s
    for s in "$PRES"/*.src; do
        case "$(cat "$s")" in "$1"|*/"$(basename "$1")") ;; *) continue ;; esac
        if [ -n "${3:-}" ]; then rm -f "$s" "${s%.src}.name"   # a short recording is not a live: no answer goes up
        else basename "$2" > "${s%.src}.name"; fi
    done
}
presenters_renamed() {   # old new: a recording got " (2)" to avoid a clash in Drive
    local s
    for s in "$PRES"/*.name; do if [ "$(cat "$s")" = "$1" ]; then printf '%s\n' "$2" > "$s"; fi; done
}
send_presenters() {   # answers whose recording has its name: "<recording>.presenters.txt" next to it in Drive
    local s b name t
    t=$(date +%s)
    for s in "$PRES"/*.names; do
        b=${s%.names}
        if [ ! -f "$b.src" ]; then rm -f "$s" "$b.at"; continue; fi
        [ -s "$b.name" ] || continue
        name=$(cat "$b.name")
        if "$RCLONE" copyto "$s" "$DEST/$name.presenters.txt" --contimeout 15s --timeout 60s >/dev/null 2>&1; then
            log "Sent who was on \"$(live_name "$name")\" to Drive ($(paste -sd ',' "$s" | sed 's/,/, /g'))."
            rm -f "$b.src" "$b.name" "$b.at" "$s"
        fi
    done
    for s in "$PRES"/*.src; do   # asked over a day ago and never answered: forget it
        b=${s%.src}
        if [ ! -f "$b.names" ] && [ $(( t - $(mtime "$s") )) -gt 86400 ]; then rm -f "$s" "$b.name"; fi
    done
}
recording_now() {   # is a live on? LIVE Studio has a recording open, or a recording changed in the last 90 seconds
    local f t on="${1:-}"   # [the recording, when the helper has just seen it appear]
    if [ -z "$on" ]; then on=$(live_studio_videos | head -n 1); fi
    if [ -z "$on" ]; then
        t=$(date +%s)
        while IFS= read -r f; do
            if [ -f "$f" ] && [ $(( t - $(mtime "$f") )) -lt 90 ]; then on=$f; break; fi
        done < <(recordings; if [ -s "$FOLLOW" ]; then cat "$FOLLOW"; fi)
    fi
    if [ -n "$on" ]; then
        if [ ! -f "$APP_DIR/live-on" ]; then   # (the live watcher below may be here at the same moment: one of them wins)
            if [ -d "$APP_DIR/live-on.lock" ] && [ $(( $(date +%s) - $(mtime "$APP_DIR/live-on.lock") )) -gt 60 ]; then rmdir "$APP_DIR/live-on.lock" 2>/dev/null; fi
            if mkdir "$APP_DIR/live-on.lock" 2>/dev/null; then
                if [ ! -f "$APP_DIR/live-on" ]; then
                    echo "$on" > "$APP_DIR/live-on"; log "Live started (file \"$on\")."; touch "$APP_DIR/status-due"
                    ask_presenters "$on"
                fi
                rmdir "$APP_DIR/live-on.lock" 2>/dev/null
            fi
        fi
        return 0
    fi
    if [ -f "$APP_DIR/live-on" ]; then
        log "Live stopped (\"$(cat "$APP_DIR/live-on")\")."; rm -f "$APP_DIR/live-on"; touch "$APP_DIR/status-due"
        keep_open_note
    fi
    return 1
}
# The live watcher: between the minute's runs, it looks every few seconds for LIVE Studio starting to record, so
# "Clock in" shows within seconds of going live, not up to a minute later (Brandon, 24 Nov). Only while nothing is
# known to be live and there are names to ask; each run starts it afresh (so it always has this run's settings).
LIVE_WATCH_EVERY="${SALSABEEL_UPLOADER_WATCH_EVERY:-3}"
live_watch() {
    local i=0
    while [ "$i" -lt $(( 54 / LIVE_WATCH_EVERY )) ]; do
        if [ -f "$APP_DIR/live-on" ]; then break; fi
        if [ -n "$(live_studio_videos | head -n 1)" ]; then recording_now >/dev/null 2>&1; break; fi
        sleep "$LIVE_WATCH_EVERY"; i=$((i + 1))
    done
    rm -f "$APP_DIR/live-watch.pid"
}
start_live_watch() {
    local old
    old=$(cat "$APP_DIR/live-watch.pid" 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then kill "$old" 2>/dev/null; fi   # only the watcher, never a "Clock in" window
    rm -f "$APP_DIR/live-watch.pid"
    [ -z "${SALSABEEL_UPLOADER_NO_WATCH:-}" ] || return 0   # (the self-test, except where it tests this)
    [ "$PRESENTERS_ASK" = on ] && [ ! -f "$APP_DIR/live-on" ] && [ -n "$(presenter_names | head -n 1)" ] || return 0
    set -m   # its own process group, so it outlives this run
    live_watch </dev/null >/dev/null 2>&1 &
    echo $! > "$APP_DIR/live-watch.pid"
    set +m
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

# --- Uploading in parts (agreed with the cloud joiner, 14 Nov 2026) -------------------------------------
# Drive: Parts/<name>/part-0001, part-0002 ... then manifest.txt, last:
#   clipline-parts 1 / name: <name> / size: <bytes> / md5: <whole file> / part: part-0001 <bytes> <md5> ...
# After joining, the cloud renames the folder "Parts/Copied - <name>"; this Mac then deletes it and its own copy.
# The parts sent so far are kept in $APP_DIR/parts/<name>, and checked against Drive before carrying on.
md5_stdin() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi; }
md5_file() { if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
gib() { awk -v b="$1" 'BEGIN { printf "%.3f GiB", b / 1073741824 }'; }
parts_prepare() {   # sets PNAME PDIR PSTATE FSIZE POFF PNUM; checks what Drive already has
    local key listing rc line tag pn off b m keep=""
    PNAME=$(basename "$SRC"); PDIR="$DEST/Parts/$PNAME"; FSIZE=$(fsize "$SRC")
    key=$(printf '%s' "$PNAME" | tr -c 'A-Za-z0-9._-' '_'); mkdir -p "$APP_DIR/parts"; PSTATE="$APP_DIR/parts/$key"
    if [ "$(sed -n 's/^size //p' "$PSTATE" 2>/dev/null)" != "$FSIZE" ]; then
        log "Working out the checksum of \"$PNAME\" ($(( FSIZE / 1048576 )) MB) before sending it in parts."
        printf 'size %s\nmd5 %s\n' "$FSIZE" "$(md5_file "$SRC")" > "$PSTATE"
    fi
    listing=$("$RCLONE" lsf "$PDIR" --files-only --format psh --hash MD5 --separator ';' --contimeout 15s --timeout 60s 2>/dev/null); rc=$?
    POFF=0; PNUM=0
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then listing="trust"; fi   # Drive not reachable: trust what is noted here
    while read -r tag pn off b m; do
        [ "$tag" = part ] || continue
        if [ "$listing" = trust ] || printf '%s\n' "$listing" | grep -qxF "$pn;$b;$m"; then
            keep="$keep$tag $pn $off $b $m
"; POFF=$(( off + b )); PNUM=$(( PNUM + 1 ))
        else
            log "Part $pn of \"$PNAME\" is not in Drive as sent: it goes again from there."; break
        fi
    done < "$PSTATE"
    { grep -E '^(size|md5) ' "$PSTATE"; printf '%s' "$keep"; } > "$PSTATE.new"; mv -f "$PSTATE.new" "$PSTATE"
    if [ "$PNUM" -gt 0 ]; then log "Carrying on with \"$PNAME\" at part $(( PNUM + 1 )): $(( POFF / 1048576 )) MB are already in Drive."; fi
}
parts_finish() {   # all parts are in: the manifest goes up last, and the recording moves out of "Ready to upload"
    local tag pn off b m
    { echo "clipline-parts 1"; echo "name: $PNAME"; echo "size: $FSIZE"; echo "md5: $(sed -n 's/^md5 //p' "$PSTATE")"
      while read -r tag pn off b m; do [ "$tag" = part ] && echo "part: $pn $b $m"; done < "$PSTATE"; } > "$PSTATE.manifest"
    "$RCLONE" copyto "$PSTATE.manifest" "$PDIR/manifest.txt" --contimeout 15s --timeout 60s --retries 3 >/dev/null 2>&1 || return 1
    mkdir -p "$WATCH_DIR/.sent" && mv -f "$SRC" "$WATCH_DIR/.sent/$PNAME" || return 1
    log "All $PNUM parts of \"$PNAME\" are in Drive, with their manifest. It is deleted here once the cloud has joined it."
}
clear_parts() {   # the cloud has joined a recording ("Parts/Copied - <name>"): delete that folder, and the copy here
    local d n
    "$RCLONE" lsf "$DEST/Parts" --dirs-only --contimeout 15s --timeout 60s > "$APP_DIR/parts-dirs" 2>/dev/null || return 0
    # Parts left from an upload that was never finished (parts were switched off, 18 Nov): once that live is no longer
    # waiting here (it went up whole), its unfinished parts only fill Google Drive. No manifest = never finished.
    if [ "$PARTS_UPLOAD" != on ]; then
        while IFS= read -r d; do
            n=${d%/}
            case "$n" in "$PREFIX "*) ;; *) continue ;; esac   # only lives this app sent (by name)
            if [ -e "$READY/$n" ] || [ -e "$WATCH_DIR/.sent/$n" ]; then continue; fi
            "$RCLONE" lsf "$DEST/Parts/$n" --files-only --contimeout 15s --timeout 60s 2>/dev/null > "$APP_DIR/parts-files" || continue
            if grep -qx 'manifest.txt' "$APP_DIR/parts-files"; then continue; fi
            if "$RCLONE" purge "$DEST/Parts/$n" --drive-use-trash=false --contimeout 15s --timeout 60s >/dev/null 2>&1; then
                rm -f "$APP_DIR/parts/$(printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_')"*
                log "Deleted the unfinished parts of \"$n\" from Google Drive ($(grep -c . "$APP_DIR/parts-files") files): parts are off, and the live itself went up whole."
            fi
        done < "$APP_DIR/parts-dirs"
    fi
    grep '^Copied - ' "$APP_DIR/parts-dirs" > "$APP_DIR/copied-parts" || return 0
    while IFS= read -r d; do
        n=${d%/}
        case "$n" in "Copied - $PREFIX "*) ;; *) continue ;; esac   # only lives this app sent (by name)
        if "$RCLONE" purge "$DEST/Parts/$n" --drive-use-trash=false --contimeout 15s --timeout 60s >/dev/null 2>&1; then
            rm -f "$WATCH_DIR/.sent/${n#Copied - }" "$APP_DIR/parts/$(printf '%s' "${n#Copied - }" | tr -c 'A-Za-z0-9._-' '_')"*
            log "The cloud has joined \"${n#Copied - }\": its parts folder and the copy here are deleted."
        fi
    done < "$APP_DIR/copied-parts"
    return 0
}

clear_copied() {   # lives the cloud has taken ("Copied - ..."): delete them here for good
    local f n=0 err t      # Only API calls, so it also runs during lives and mid-upload (see the upload loop).
    t=$(date +%s)
    if [ ! -f "$APP_DIR/full-noted" ] && [ -f "$APP_DIR/cleared-checked" ] &&
       [ $(( t - $(mtime "$APP_DIR/cleared-checked") )) -lt "$CLEAR_EVERY" ]; then return 0; fi
    touch "$APP_DIR/cleared-checked"
    clear_parts
    "$RCLONE" lsf "$DEST" --files-only --contimeout 15s --timeout 60s > "$APP_DIR/drive-files" 2>/dev/null || return 0
    grep '^Copied - ' "$APP_DIR/drive-files" > "$APP_DIR/copied" || return 0
    while IFS= read -r f; do
        case "$f" in "Copied - $PREFIX "*) ;; *) continue ;; esac   # only lives this app uploaded (by name)
        case "$f" in *.presenters.txt)   # who was on a live the cloud has taken (if it renamed it too)
            "$RCLONE" deletefile "$DEST/$f" --drive-use-trash=false --contimeout 15s --timeout 60s >/dev/null 2>&1; continue ;; esac
        is_video "$f" || continue
        if grep -qxF -- "${f#Copied - }.presenters.txt" "$APP_DIR/drive-files"; then   # its "who was on" too
            "$RCLONE" deletefile "$DEST/${f#Copied - }.presenters.txt" --drive-use-trash=false --contimeout 15s --timeout 60s >/dev/null 2>&1 || true
        fi
        if err=$("$RCLONE" deletefile "$DEST/$f" --drive-use-trash=false --contimeout 15s --timeout 60s 2>&1); then
            log "Deleted \"$f\" from this Google Drive: the cloud has its own copy."
            n=$((n + 1))
        else
            warn_copied "$f" "$(printf '%s' "$err" | tail -n 1)"
        fi
    done < "$APP_DIR/copied"
    if [ "$n" -gt 0 ]; then STATUS_NOW=1; fi
    return 0
}
warn_copied() {   # a delete that failed: logged once an hour per file, with rclone's reason
    local key
    key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
    if [ -f "$APP_DIR/copied-failed.$key" ] && [ $(( $(date +%s) - $(mtime "$APP_DIR/copied-failed.$key") )) -lt 3600 ]; then return 0; fi
    touch "$APP_DIR/copied-failed.$key"
    log "Could not delete \"$1\" from Google Drive: ${2:-no reason given}"
}
# Brandon, 12 Nov 2026: "yes, empty the bin but only the live stream files".
# Only this app's own files (drive.file), only on Google Drive, and only live recordings:
# "Salsabeel live ..." or "Copied - Salsabeel live ..." videos. Never the status note, fix reports,
# short recordings, or anything else; anything it isn't sure of stays.
is_live_file() {
    case "$1" in "$CHECKS_FOLDER"/*|*/"$CHECKS_FOLDER"/*) return 1 ;; esac
    printf '%s' "${1##*/}" | grep -qiE '^(Copied - )?Salsabeel live .*\.(mp4|mov|m4v)$'
}
empty_bin() {   # [now]: once an hour (and straight after Drive reads full), delete this app's live recordings in the bin for good
    local line size path n=0
    is_remote && "$RCLONE" listremotes --long 2>/dev/null | grep -qE "^$REMOTE: +drive *\$" || return 0
    if [ -z "${1:-}" ] && [ -f "$APP_DIR/bin-checked" ] &&
       [ $(( $(date +%s) - $(mtime "$APP_DIR/bin-checked") )) -lt 3600 ]; then return 0; fi
    touch "$APP_DIR/bin-checked"
    "$RCLONE" lsf "$REMOTE:" -R --files-only --format sp --separator ';' --drive-trashed-only \
        --contimeout 15s --timeout 60s > "$APP_DIR/bin-list" 2>/dev/null || return 0
    while IFS= read -r line; do
        size=${line%%;*}; path=${line#*;}
        case "$size" in ''|*[!0-9]*) continue ;; esac
        case "$path" in "${DEST#*:}"/*) ;; *) continue ;; esac   # only inside the lives folder (by path)
        is_live_file "$path" || continue
        if "$RCLONE" deletefile "$REMOTE:$path" --drive-trashed-only --drive-use-trash=false \
               --contimeout 15s --timeout 60s >/dev/null 2>&1; then
            log "Emptied from the Google Drive bin for good: \"$path\" ($(( size / 1048576 )) MB)."
            n=$((n + 1))
        fi
    done < "$APP_DIR/bin-list"
    if [ "$n" -gt 0 ]; then STATUS_NOW=1; fi
    return 0
}

if [ "${1:-}" = --clock-in-helper ]; then clock_in_helper; exit 0; fi
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
clear_copied   # first: it frees space for the Drive check below
empty_bin
read_presenters
start_live_watch
ensure_helper
rescue_moved

pending() { find "$READY" -type f ! -name '.*' 2>/dev/null; }
label() { pending | while IFS= read -r f; do basename "$f"; done | paste -sd ',' - | sed 's/,/, /g'; }
waiting=$(pending | grep -c . || true)
echo "$waiting" > "$APP_DIR/waiting-count"
if [ "$waiting" -eq 0 ]; then
    if recording_now; then NOW_LINE="A live is on: nothing waits to upload"; BUSY=1; fi
    send_presenters
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

# Google Drive asked to slow down (a rate limit): no upload until the wait is over, so it is not made worse
if [ -f "$APP_DIR/rate-wait" ]; then
    read -r rw_until rw_mins < "$APP_DIR/rate-wait" 2>/dev/null
    if [ "${rw_until:-0}" -gt "$(date +%s)" ] 2>/dev/null; then
        NOW_LINE="Google Drive asked to slow down: the next try is at $(clock_of "$rw_until" %H:%M)"
        status_slowdown "$(clock_of "$rw_until" %H:%M)"
        status_if_due; exit 0
    fi
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
        mv -n "$f" "$READY/$stem ($n).$ext" && presenters_renamed "$base" "$stem ($n).$ext" && base="$stem ($n).$ext"
    fi
    existing="$existing
$base"
done
waiting=$(pending | grep -c . || true)
FILES_LABEL=$(label)
send_presenters   # (after any renaming above)

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
        break   # one at a time, oldest first: each file finishes before the next starts
    fi
done < <(pending | sort)
if [ "$count" -eq 0 ]; then
    msg="Google Drive is full ($(( ${free:-0} / 1048576 )) MB free): $waiting recording(s) wait on this Mac until there is room."
    if [ "$(cat "$APP_DIR/full-noted" 2>/dev/null)" != "$msg" ]; then log "$msg"; echo "$msg" > "$APP_DIR/full-noted"; fi
    pct=0
    status_full
    now_full "$waiting"
    empty_bin now   # the bin may hold old lives that still count against the space
    status_if_due
    exit 0
fi
rm -f "$APP_DIR/full-noted"
PROGRESS="$APP_DIR/upload-progress.log"
short_urls() { sed -E 's#(https?://[^?" ]*)\?[^" ]*#\1#g'; }   # a web address's long tail cut off, so the reason fits in the note
: > "$PROGRESS"
SRC="$READY/$(head -n 1 "$APP_DIR/to-upload")"; PARTS=""
if [ "$PARTS_UPLOAD" = on ] && [ "$(dirname "$(head -n 1 "$APP_DIR/to-upload")")" = . ] &&
   [ "$(fsize "$SRC")" -ge $(( PARTS_MIN_MB * 1048576 )) ]; then
    PARTS=1; parts_prepare
fi
start_upload() {   # the next rclone: the whole file, or the next part; sets rclone_pid (and RC_URL)
    local port common bytes count
    : > "$PROGRESS"; port=$(rc_port); RC_URL=""
    if [ "$port" != 0 ]; then RC_URL="http://127.0.0.1:$port/"; fi
    # Its remote control: local only, with a new random password each time. Newer rclone needs a login even to change
    # the speed ("authentication must be set up on the rc server to use core/bwlimit", seen on the Mac, 16 Nov).
    RC_PASS=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ -z "$RC_PASS" ]; then RC_PASS="p$RANDOM$RANDOM$RANDOM"; fi
    # DEBUG: rclone says why it starts a file again only at this level ("Received error: … - low level retry n/20")
    common=(--stats 2s --stats-one-line --stats-log-level NOTICE --log-level DEBUG --log-file "$PROGRESS"
            --rc --rc-addr "127.0.0.1:$port" --rc-user salsabeel --rc-pass "$RC_PASS")
    USR2=""   # rclone toggles its --bwlimit on and off on SIGUSR2: a second way to slow it, if its remote control fails
    if [ "$mode" = live ]; then common+=(--bwlimit "$(rate_of "$cap")")
    elif [ -n "$BWLIMIT" ]; then common+=(--bwlimit "$BWLIMIT")
    else USR2_RATE=$(ceiling_kbit); common+=(--bwlimit "$(rate_of "$USR2_RATE")"); USR2=starting; fi   # full speed once it runs
    if [ -n "$PARTS" ]; then
        count=$PART_MB; if [ "$mode" = live ]; then count=$PART_LIVE_MB; fi
        bytes=$(( count * 1048576 )); if [ $(( FSIZE - POFF )) -lt "$bytes" ]; then bytes=$(( FSIZE - POFF )); fi
        PPART=$(printf 'part-%04d' $(( PNUM + 1 ))); PBYTES=$bytes
        PMD5=$(dd if="$SRC" bs=1048576 skip=$(( POFF / 1048576 )) count="$count" 2>/dev/null | md5_stdin)
        # Fewer Drive calls per part: at most PARTS_TPS a second, and bigger pieces (Drive's "rateLimitExceeded", 18 Nov)
        dd if="$SRC" bs=1048576 skip=$(( POFF / 1048576 )) count="$count" 2>/dev/null |
            "$RCLONE" rcat "$PDIR/$PPART" --size "$bytes" --low-level-retries 20 --tpslimit "$PARTS_TPS" --tpslimit-burst 1 \
                --drive-chunk-size "$PARTS_CHUNK" "${common[@]}" &
    else
        "$RCLONE" move "$READY" "$DEST" --files-from "$APP_DIR/to-upload" --transfers 1 --retries 3 --low-level-retries 20 \
            "${common[@]}" &
    fi
    rclone_pid=$!
    if command -v caffeinate >/dev/null 2>&1; then caffeinate -ims -w "$rclone_pid" & fi   # no sleeping mid-upload
}
part_landed() {   # the part just sent: in Drive with its size and md5?
    "$RCLONE" lsf "$PDIR" --files-only --format psh --hash MD5 --separator ';' --contimeout 15s --timeout 60s 2>/dev/null |
        grep -qxF "$PPART;$PBYTES;$PMD5"
}
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
    mode=live
else
    log "Uploading $(head -n 1 "$APP_DIR/to-upload" | sed 's#.*/##') ($(( total / 1048576 )) MB) to $DEST$([ -n "$PARTS" ] && echo ", in parts")"
    mode=full
fi
started=$(date +%s)
full_t=$started; full_b=${POFF:-0}   # since when (and from how many bytes sent) it has been at full speed: for the line's speed
sent=${POFF:-0}                      # bytes sent so far, from rclone's progress
start_upload
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
waited=""
status_pid=""
status_tried=0
checked=$(date +%s); good_since=$checked; bad=0; last_tick=$checked
ok=""
resent=""; err_logged=""; tot_first=""
while :; do   # once for a whole file; once per part when sending in parts
while kill -0 "$rclone_pid" 2>/dev/null; do
    ticks=$((ticks + 1))
    now_s=$(date +%s)
    if [ $(( now_s - last_tick )) -ge "$SLEEP_GAP_SECONDS" ]; then   # the Mac really slept mid-upload
        PREV_RUN=$last_tick; echo "$waiting" > "$APP_DIR/waiting-count"; note_sleep
    fi
    last_tick=$now_s; touch "$APP_DIR/last-run"   # (launchd starts no other run while this one goes on)
    if [ $((ticks % 15)) -eq 0 ]; then start_live_watch; fi   # so a live starting mid-upload is seen within seconds
    if [ $((ticks % 15)) -eq 0 ]; then   # a new version is installed now, and takes over after the upload ...
        UPDATED=""
        update_if_due
        if [ -n "$UPDATED" ]; then   # ... but never by stopping an upload: that would start the file again from zero
            log "The new version takes over after this upload (the upload carries on)."
        fi
        read_presenters; send_presenters
    fi
    if [ "$mode" = full ] && [ $(( now_s - full_t )) -ge "$LINE_SAMPLE_EVERY" ]; then   # a reading every 10 minutes
        line_sample $(( sent - full_b )) $(( now_s - full_t )); full_t=$now_s; full_b=$sent
    fi
    if [ "$USR2" = starting ] && grep -q '%' "$PROGRESS" 2>/dev/null; then   # running (signals before that would stop it)
        kill -USR2 "$rclone_pid" 2>/dev/null && USR2=off                         # full speed
    fi
    clear_copied; empty_bin   # during long (live) uploads too: only API calls (each checks its own timer)
    if [ $((ticks % 8)) -eq 0 ]; then
        if [ "$mode" = full ] && recording_now; then   # a live has started: slow down (or wait), never start again
            line_sample $(( sent - full_b )) $(( now_s - full_t ))
            if [ "$LIVE_UPLOAD" = on ] && set_cap "$(cap_min)" "a live started"; then   # (rclone answers only while running)
                kill -STOP "$rclone_pid" 2>/dev/null; measure_line; kill -CONT "$rclone_pid" 2>/dev/null
                base=$LAT; guard=$([ -n "$base" ] && echo 1); limit=$(ceiling_kbit)
                log "The line's delay is ${base:-unknown} ms (measured while not uploading)."
                mode=live; BUSY=1; checked=$(date +%s); good_since=$checked; bad=0
            elif [ "$LIVE_UPLOAD" = on ] && { [ "$USR2" = starting ] || { [ "$USR2" = off ] && kill -USR2 "$rclone_pid" 2>/dev/null; }; }; then
                # its remote control did not answer: the signal puts it back to the live ceiling it started with
                USR2=on; cap=$USR2_RATE; limit=$cap
                kill -STOP "$rclone_pid" 2>/dev/null; measure_line; kill -CONT "$rclone_pid" 2>/dev/null
                base=$LAT; guard=$([ -n "$base" ] && echo 1)
                log "Upload speed during the live: $(mbit_of "$cap") Mbit/s (set by signal: its remote control did not answer). The line's delay is ${base:-unknown} ms; it pauses if the stream suffers."
                mode=live; BUSY=1; checked=$(date +%s); good_since=$checked; bad=0
            else   # it can't slow down (or LIVE_UPLOAD=off): it waits, paused, keeping what it has sent
                kill -STOP "$rclone_pid" 2>/dev/null
                mode=live; waited=1; BUSY=1; touch "$APP_DIR/paused"
                log "A live started: the upload is paused until it ends (what it has sent is kept)."
                status_paused; now_live "$waiting"
            fi
        elif [ "$mode" = live ] && ! recording_now; then   # the live has ended: full speed at once
            kill -CONT "$rclone_pid" 2>/dev/null; held=""
            if rc_bwlimit "$(full_rate)"; then :
            elif [ "$USR2" = on ] && kill -USR2 "$rclone_pid" 2>/dev/null; then USR2=off   # (by signal)
            else log "Its speed could not be raised; it carries on at the speed it had."; fi
            if [ -n "$waited" ]; then rm -f "$APP_DIR/paused"; waited=""; log "The recording has stopped: the upload carries on."
            else log "The live has ended: uploading at full speed."; fi
            mode=full; full_t=$(date +%s); full_b=$sent
        fi
    fi
    if [ -n "$waited" ]; then
        :   # paused until the live ends (above)
    elif [ -n "$held" ]; then
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
    if [ -z "$err_logged" ] && grep -qE 'ERROR|low level retry' "$PROGRESS" 2>/dev/null; then   # seen as it happens, not hours later
        err_logged=1; log "rclone says (it keeps trying): $(grep -m 1 -E 'ERROR|low level retry' "$PROGRESS" | short_urls | cut -c1-300)"
    fi
    line=$(grep -E ' / .*[0-9]+%' "$PROGRESS" 2>/dev/null | tail -n 1)
    if [ -z "$held" ] && [ -n "$line" ]; then
        pct=$(printf '%s' "$line" | grep -oE '[0-9]+%' | tail -n 1 | tr -d '%')
        sizes=$(printf '%s' "$line" | sed -nE 's#.* ([0-9.]+ [KMGTP]?i?B) / ([0-9.]+ [KMGTP]?i?B),.*#\1 / \2#p')
        eta=$(printf '%s' "$line" | sed -nE 's/.*ETA ([^ ]+).*/\1/p')
        if [ -n "$sizes" ]; then sent=$(to_bytes "${sizes% / *}"); fi
        # rclone starts a refused file again from zero (up to 20 times), and adds each try to its total: once the total
        # has grown past 1.5 times what it first said, it's going round in circles (19 Nov: 105 GB for a 5 GB live).
        # Stop, and let the wait below take over.
        if [ -n "$sizes" ] && [ -z "$PARTS" ] && [ -z "$resent" ]; then
            tot_now=$(to_bytes "${sizes#* / }")
            if [ -z "$tot_first" ]; then tot_first=$tot_now
            elif [ "$tot_now" -gt $(( tot_first * 3 / 2 )) ]; then
                resent=1
                log "Google Drive keeps refusing the end of this upload and rclone keeps starting it again ($(human_size "${sizes#* / }") sent for a $(( total / 1048576 )) MB file), so it stops here."
                stop_upload
            fi
        fi
        if [ -n "$PARTS" ] && [ -n "$sizes" ]; then   # the whole recording, not just this part
            sent=$(( POFF + sent )); pct=$(( sent * 100 / FSIZE )); sizes="$(gib "$sent") / $(gib "$FSIZE")"
            rate=$(printf '%s' "$line" | sed -nE 's#.*, ([0-9.]+ [KMGT]?i?B)/s,.*#\1#p')
            if [ -n "$rate" ] && [ "$(to_bytes "$rate")" -gt 0 ]; then
                t=$(( (FSIZE - sent) / $(to_bytes "$rate") )); eta="$(( t / 3600 ))h$(( t % 3600 / 60 ))m$(( t % 60 ))s"
            fi
        fi
        if [ -n "$pct" ] && [ -n "$sizes" ]; then
            if [ -n "$waited" ]; then :   # paused until the live ends: the page and Now line say so (not "uploading slowly")
            elif [ "$mode" = live ]; then status_slow "$pct" "$sizes"; else status_uploading "$pct" "$sizes" "$eta"; fi
        fi
    fi
    # The note in Drive, mid-upload, every 5 minutes: in the background, so this loop is not held up.
    if [ -n "$NOW_LINE" ]; then
        t=$(date +%s)
        if { { [ -f "$APP_DIR/status-due" ] && [ $(( t - status_tried )) -ge 30 ]; } ||
             { [ $(( t - $(mtime "$APP_DIR/status-sent" 2>/dev/null || echo 0) )) -ge "$STATUS_BUSY_EVERY" ] &&
               [ $(( t - status_tried )) -ge "$STATUS_BUSY_EVERY" ]; }; } &&
           { [ -z "$status_pid" ] || ! kill -0 "$status_pid" 2>/dev/null; }; then
            status_tried=$t
            send_status >/dev/null 2>&1 &
            status_pid=$!
        fi
    fi
    sleep 2
done
if ! wait "$rclone_pid" || [ -n "$resent" ]; then break; fi
if [ -z "$PARTS" ]; then ok=1; break; fi
if ! part_landed; then log "$PPART of \"$PNAME\" did not check out in Drive; it goes again next time."; break; fi
printf 'part %s %s %s %s\n' "$PPART" "$POFF" "$PBYTES" "$PMD5" >> "$PSTATE"
POFF=$(( POFF + PBYTES )); PNUM=$(( PNUM + 1 )); sent=$POFF
if [ "$POFF" -ge "$FSIZE" ]; then parts_finish && ok=1; break; fi
start_upload
done
left=$(pending | grep -c . || true)
if [ -n "$paused" ]; then
    if [ "$LIVE_UPLOAD" = on ]; then
        log "A live started, so the upload stopped. It carries on slowly in a minute."
    else
        log "A live started, so the upload stopped. It carries on by itself once the recording stops."
        touch "$APP_DIR/paused"
    fi
    status_paused
    now_live "$left"
elif [ -n "$ok" ]; then
    log "Uploaded to $DEST"
    rm -f "$APP_DIR/rate-wait"   # Drive is happy again
    if [ -n "$PARTS" ]; then total=$FSIZE; fi
    if [ "$mode" = full ]; then line_sample $(( total - full_b )) $(( $(date +%s) - full_t )); fi   # the line's speed
    status_done
    if [ "$mode" = full ]; then notify "The live recording is in Google Drive. You can turn the Mac off."; fi
    NOW_LINE="Nothing to upload"
    if [ "$mode" = live ] && [ "$left" -gt 0 ]; then NOW_LINE="A live is on: $(plural "$left" "upload waits" "uploads wait"), the next goes slowly in a minute"
    elif [ "$left" -gt 0 ]; then NOW_LINE="Uploaded one: $(plural "$left" "live waits" "lives wait"), the next starts within a minute"; fi
else
    { grep -m 2 -E 'ERROR|low level retry|Failed to' "$PROGRESS" | short_urls | cut -c1-300   # the head of rclone's error (what failed, and why) ...
      grep -vE ' / .*[0-9]+%' "$PROGRESS" | tail -n 5 | short_urls; } >> "$LOG"           # ... and its end
    if grep -qiE 'storageQuotaExceeded|quota has been exceeded|quotaExceeded' "$PROGRESS"; then
        log "Google Drive is full: it stays in \"Ready to upload\" and is tried again in a minute."
        status_full
        now_full "$left"
    elif [ -n "$resent" ] || grep -qiE 'rateLimitExceeded|userRateLimitExceeded|rate limit exceeded|Error 429|too many requests' "$PROGRESS"; then
        # Not the internet: Google Drive wants fewer requests for a while. Wait, twice as long each time in a row.
        rw_mins=$RATE_WAIT_MIN
        if [ -f "$APP_DIR/rate-wait" ]; then
            read -r rw_until rw_mins < "$APP_DIR/rate-wait" 2>/dev/null
            rw_mins=$(( ${rw_mins:-$RATE_WAIT_MIN} * 2 )); if [ "$rw_mins" -gt "$RATE_WAIT_MAX" ]; then rw_mins=$RATE_WAIT_MAX; fi
        fi
        rw_until=$(( $(date +%s) + rw_mins * 60 ))
        echo "$rw_until $rw_mins" > "$APP_DIR/rate-wait"
        if [ -n "$resent" ]; then why="Google Drive kept refusing the upload"; else why="Google Drive asked to slow down (rate limit)"; fi
        log "$why, so it waits $(plural "$rw_mins" minute minutes) before trying again (what is in Drive is kept)."
        status_slowdown "$(clock_of "$rw_until" %H:%M)"
        NOW_LINE="Google Drive asked to slow down: the next try is at $(clock_of "$rw_until" %H:%M)"
    else
        log "Upload failed; it stays in \"Ready to upload\" and is tried again in a minute."
        status_retry "${pct:-0}"
        NOW_LINE="Waiting for the internet"
    fi
fi
if [ -n "$status_pid" ]; then wait "$status_pid" 2>/dev/null; fi   # never two notes going up at once
STATUS_NOW=1
status_if_due
