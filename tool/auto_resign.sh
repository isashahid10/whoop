#!/usr/bin/env bash
#
# auto_resign.sh - keep the app signed without thinking about it.
#
# A free Apple account signs an app for 7 days. After that iOS refuses to
# launch it and the fix is a rebuild plus an install, which is fine once and
# tedious forever. This does it unattended.
#
# DESIGNED TO DO NOTHING MOST OF THE TIME. It runs often, checks two cheap
# conditions, and exits silently unless there is real work:
#
#   1. Is the signature close to expiring? If not, stop. Rebuilding a healthy
#      app wastes several minutes of CPU and risks breaking something that
#      currently works.
#   2. Is the phone actually reachable? If not, stop quietly and try later.
#      A missing phone is the normal case, not an error worth reporting.
#
# IT BACKS UP FIRST, ALWAYS. An install is the one moment the app's container
# is at risk, and this database holds months of irreplaceable sleep and
# training history that cannot be re-collected. A failed backup ABORTS the
# install: a stale signature is a nuisance, lost data is not.
#
# Install with:  ./tool/auto_resign.sh --install-schedule
# Check status:  ./tool/auto_resign.sh --status
# Run by hand:   ./tool/auto_resign.sh

set -uo pipefail

# ── configuration ───────────────────────────────────────────────────────────

REPO="/Volumes/University/Personal Projects/Whoop/edge"
BACKUPS="/Volumes/University/Personal Projects/Whoop/backups"
DEVICE="C1DE1732-D648-5A2C-B675-98401A2FEFE6"
BUNDLE="com.isashahid.openstrapEdge"

# Re-sign when fewer than this many days remain.
#
# WIDENED FROM 3 AFTER A REAL OUTAGE. The job only runs while the Mac is
# awake, and the log shows a gap from 2026-10-02 to 10-08 with no runs at all
# (laptop closed). With a 3-day window the first run after that found 0 days
# left, the build then failed, and the app was dead for two days. Five means
# a re-sign roughly every other day the Mac is open, and a Mac that is shut
# for up to five days still comes back to a working app.
RENEW_WITHIN_DAYS=5

# Keep this many backups. Each is a few hundred MB, so unbounded retention
# quietly fills the disk that is meant to be protecting the data.
KEEP_BACKUPS=12

# How old an existing backup may be and still cover an install.
#
# WIDENED FROM 72h AFTER A REAL DEADLOCK. The container pull fails often, and
# with a 3-day window the script reached a state it could not leave: the pull
# failed, the newest backup was already older than the window, so it refused to
# install - and because it never installed, no newer backup was ever taken.
# Observed twice in the log before it was caught.
#
# Two weeks reflects the actual risk. devicectl performs an UPGRADE install and
# has never once replaced the container across dozens of installs in this
# project. Weighed against that, an app that has permanently stopped launching
# is a certainty rather than a hypothetical.
BACKUP_MAX_AGE_HOURS=336

# Below this many days remaining, install even with no usable backup at all.
#
# At that point the app is about to stop working entirely, and refusing to fix
# it protects nothing: the data is equally inaccessible either way, and an
# upgrade install is the same operation that has always preserved it.
FORCE_BELOW_DAYS=1

LOG="$HOME/Library/Logs/whoop-resign.log"
LABEL="com.isashahid.whoop.resign"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# launchd starts with almost no PATH, so every tool is found explicitly.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# Only used for outcomes worth interrupting someone about.
notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

# ── subcommands ─────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--install-schedule" ]]; then
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REPO/tool/auto_resign.sh</string>
  </array>
  <!-- Every 6 hours. The script itself decides whether there is anything to
       do, so a frequent trigger costs nothing and means the window in which
       the phone must be reachable is wide. -->
  <key>StartInterval</key><integer>21600</integer>
  <!-- Run on load too, so installing the schedule checks immediately. -->
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "Scheduled. Runs every 6 hours, and on login."
  echo "  log:    $LOG"
  echo "  remove: ./tool/auto_resign.sh --uninstall-schedule"
  exit 0
fi

if [[ "${1:-}" == "--uninstall-schedule" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Schedule removed."
  exit 0
fi

if [[ "${1:-}" == "--status" ]]; then
  app="$REPO/build/ios/iphoneos/Runner.app"
  if [[ -d "$app" ]]; then
    exp=$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw - 2>/dev/null)
    if [[ -n "$exp" ]]; then
      left=$(( ( $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp" "+%s" 2>/dev/null || echo 0) \
                 - $(date "+%s") ) / 86400 ))
      echo "signature expires: $exp  (${left} days)"
    fi
  fi
  launchctl list | grep -q "$LABEL" && echo "schedule: active" || echo "schedule: not installed"
  echo "recent log:"
  tail -6 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  exit 0
fi

# ── the actual run ──────────────────────────────────────────────────────────

cd "$REPO" || { log "FAIL repo not found at $REPO"; exit 1; }

# 1. Does the signature need renewing?
APP="$REPO/build/ios/iphoneos/Runner.app"
NEED_BUILD=1
if [[ -d "$APP" ]]; then
  EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
        | plutil -extract ExpirationDate raw - 2>/dev/null)
  if [[ -n "$EXP" ]]; then
    EXP_S=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" "+%s" 2>/dev/null || echo 0)
    DAYS_LEFT=$(( (EXP_S - $(date "+%s")) / 86400 ))
    if (( DAYS_LEFT > RENEW_WITHIN_DAYS )); then
      # Healthy. This is the common path and stays silent.
      exit 0
    fi
    log "signature has ${DAYS_LEFT}d left, renewing"
    NEED_BUILD=1
  fi
fi

# 2. Is the phone reachable? Not an error - just try again later.
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE.*available"; then
  log "phone not reachable, will retry"
  exit 0
fi

log "phone reachable, starting"

# 3. Back up BEFORE touching anything. A failed backup aborts the run.
mkdir -p "$BACKUPS"
TMP=$(mktemp -d)
BACKED_UP=0
for attempt in 1 2 3 4 5; do
  rm -rf "${TMP:?}/pull"; mkdir -p "$TMP/pull"
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents --destination "$TMP/pull" >/dev/null 2>&1
  db="$TMP/pull/whoop.db"
  if [[ -f "$db" ]] && [[ $(stat -f%z "$db") -gt 1000000 ]] \
     && sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok"; then
    stamp=$(date '+%Y%m%dT%H%M')
    cp "$db" "$BACKUPS/whoop_auto_$stamp.db"
    log "backed up whoop_auto_$stamp.db ($(( $(stat -f%z "$db") / 1048576 )) MB)"
    BACKED_UP=1
    break
  fi
  sleep 5
done
rm -rf "$TMP"

if (( BACKED_UP == 0 )); then
  # Fresh backup failed. Fall back to an existing recent one rather than
  # abandoning the run: an upgrade install has never replaced the container,
  # and a permanently-expired app is a certain failure against a theoretical
  # one. With NO recent backup at all, stop - that is a real risk.
  recent=$(find "$BACKUPS" -name 'whoop*.db' -mmin -$((BACKUP_MAX_AGE_HOURS * 60)) 2>/dev/null | head -1)
  if [[ -n "$recent" ]]; then
    log "WARN backup pull failed; proceeding on $(basename "$recent")"
  elif (( DAYS_LEFT <= FORCE_BELOW_DAYS )); then
    log "WARN no usable backup, but signature expires in ${DAYS_LEFT}d - installing anyway"
    notify "Whoop re-signing without a backup" "Could not back up, but the app expires in ${DAYS_LEFT} day(s)."
  else
    log "FAIL no fresh backup and none newer than ${BACKUP_MAX_AGE_HOURS}h - NOT installing"
    notify "Whoop re-sign skipped" "Could not back up and no recent backup exists. Nothing was changed."
    exit 1
  fi
fi

# Retention, oldest first.
ls -1t "$BACKUPS"/whoop_auto_*.db 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) \
  | while read -r old; do rm -f "$old" && log "pruned $(basename "$old")"; done

# 4. Rebuild for a fresh provisioning profile.
#
# CLEARING THE CACHE IS THE WHOLE POINT. Xcode reuses a cached profile until it
# actually expires, so `flutter build` alone produces a new binary carrying the
# SAME 7-day profile and the same expiry date. Observed directly: two rebuilds
# in a row both came out valid until 2026-09-08. Deleting the cache makes Xcode
# request a fresh one, which moved the expiry out by a full week.
#
# The cached profiles are free to discard: they are reissued on demand from the
# Apple ID already signed in.
if (( NEED_BUILD )); then
  # MOVED ASIDE, NOT DELETED, so a failed build can put them back. On
  # 2026-10-09 Xcode had been signed out of the Apple ID ("No Accounts"), the
  # profiles were already gone, and nothing could be signed until a manual
  # fix. Restoring them at least returns things to how they were.
  PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  STASH=$(mktemp -d)
  mv "$PROFILES/"*.mobileprovision "$STASH/" 2>/dev/null
  log "moved cached provisioning profiles aside"

  if [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    # Not an error: the working tree IS what gets installed by hand too, and
    # building something else here could downgrade the app's database schema.
    log "note: building a working tree with uncommitted changes"
  fi

  BUILD_OUT=$(mktemp)
  if ! fvm flutter build ios --release --dart-define-from-file=.env >"$BUILD_OUT" 2>&1; then
    cat "$BUILD_OUT" >> "$LOG"
    mkdir -p "$PROFILES"
    mv "$STASH/"*.mobileprovision "$PROFILES/" 2>/dev/null
    rm -rf "$STASH" "$BUILD_OUT"
    if tail -80 "$LOG" | grep -q "No Accounts"; then
      log "FAIL build: Xcode is signed out of the Apple ID (profiles restored)"
      notify "Whoop re-sign needs you" "Xcode is signed out. Open Xcode > Settings > Accounts and sign in. App expires in ${DAYS_LEFT:-?} day(s)."
    else
      log "FAIL build (profiles restored)"
      notify "Whoop re-sign failed" "Build error. See ~/Library/Logs/whoop-resign.log"
    fi
    exit 1
  fi
  cat "$BUILD_OUT" >> "$LOG"
  rm -rf "$STASH" "$BUILD_OUT"
  log "built"
fi

# 5. Install. devicectl performs an UPGRADE install, so the container and its
#    database survive. `flutter install` would uninstall first and wipe it.
# The phone drops in and out: it can pass the availability check above and be
# gone by the time the build finishes several minutes later. So this retries
# patiently rather than giving up after three quick tries.
for attempt in $(seq 1 20); do
  out=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1)
  if grep -q "App installed" <<<"$out"; then
    exp=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw - 2>/dev/null)
    log "INSTALLED, valid until $exp"
    notify "Whoop re-signed" "Good until ${exp%%T*}."
    exit 0
  fi
  # Capture whichever form the failure takes: devicectl reports some errors
  # as a bare ERROR line and others only in the localized keys.
  reason=$(grep -oE 'NSLocalizedFailureReason = .*|ERROR: .*' <<<"$out" | head -1 | cut -c1-120)
  # Only log every fifth attempt: waiting for a phone to reappear is normal
  # and should not fill the log with it.
  if (( attempt % 5 == 1 )); then
    log "install attempt $attempt: ${reason:-unknown}"
  fi
  sleep 30
done

log "FAIL install after 20 attempts over ~10 minutes"
notify "Whoop re-sign failed" "Could not install. Data is backed up and safe."
exit 1
