#!/system/bin/sh
# boot-completed.sh — runs ONLY when Android confirms boot completed.
# This is the authoritative "healthy boot" signal. Reaching this point means
# the device booted successfully WITH our tuning applied, so we clear the
# bootloop counter. If a bad setting had looped the device, we'd never get here
# and post-fs-data.sh would eventually trip safe mode.

STATE_DIR="${STATE_DIR:-/data/adb/exynos9820_tune}"
COUNTER_FILE="$STATE_DIR/bootcount"

log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '')" "$*" >>"$STATE_DIR/guard.log" 2>/dev/null; }

mkdir -p "$STATE_DIR" 2>/dev/null

# Don't clear the counter while in safe mode — the user hasn't fixed anything,
# and we want the recovery state to persist until they act via the UI.
if [ -f "$STATE_DIR/safemode" ]; then
    log "boot-completed: safe mode active, leaving counter/state as-is"
    exit 0
fi

echo "0" > "$COUNTER_FILE"
echo "healthy" > "$STATE_DIR/status"
log "boot-completed: healthy boot confirmed -> bootloop counter cleared"
exit 0
