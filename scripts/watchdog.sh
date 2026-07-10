#!/system/bin/sh
# watchdog.sh — bounded background helper launched by service.sh.
# ONE job: re-assert the saved config a few times over the first ~60s, because
# some vendor services rewrite GPU/thermal tables during early boot.
# Re-applying corrects that WITHOUT leaving a permanent process running.
#
# It is NOT a forever-loop and it does NOT decide boot health — that's
# boot-completed.sh's job (the authoritative Android signal). After its window
# closes, the watchdog exits.

STATE_DIR="${STATE_DIR:-/data/adb/exynos9820_tune}"
CONFIG="${CONFIG:-$STATE_DIR/config.conf}"
VMARGIN_CONFIG="${VMARGIN_CONFIG:-$STATE_DIR/vmargin.conf}"
MODDIR="${MODDIR:-${0%/*}/..}"
APPLY="$MODDIR/scripts/apply.sh"
ROOT="${ROOT-}"

REASSERT_TIMES="${REASSERT_TIMES:-4}"
REASSERT_INTERVAL="${REASSERT_INTERVAL:-15}"

log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '')" "$*" >>"$STATE_DIR/guard.log" 2>/dev/null; }

log "watchdog: start (reassert ${REASSERT_TIMES}x @ ${REASSERT_INTERVAL}s)"

if [ -f "$STATE_DIR/safemode" ]; then
    log "watchdog: safe mode active -> standing down"
    exit 0
fi

i=0
while [ "$i" -lt "$REASSERT_TIMES" ]; do
    i=$((i + 1))
    if [ -r "$CONFIG" ]; then
        ROOT="$ROOT" LOG="$STATE_DIR/guard.log" sh "$APPLY" "$CONFIG" >/dev/null 2>&1
        log "watchdog: re-assert pass $i"
    fi
    # Voltage margins get the same re-assert protection as the main tuning
    # config — a vendor power/thermal daemon touching /sys/power/percent_margin
    # early in boot is exactly the class of problem this watchdog exists for.
    if [ -r "$VMARGIN_CONFIG" ]; then
        ROOT="$ROOT" LOG="$STATE_DIR/guard.log" sh "$APPLY" "$VMARGIN_CONFIG" >/dev/null 2>&1
        log "watchdog: vmargin re-assert pass $i"
    fi
    [ "$i" -lt "$REASSERT_TIMES" ] && sleep "$REASSERT_INTERVAL"
done

log "watchdog: done"
exit 0
