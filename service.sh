#!/system/bin/sh
# service.sh — runs at LATE boot (system mostly up). Applies the user's saved
# tuning config, unless safe mode is engaged. Then launches a bounded watchdog
# that re-asserts settings (to beat vendor services that stomp GPU/thermal
# tables during early boot) and, once boot is confirmed healthy, clears the
# bootloop counter.

MODDIR="${MODDIR:-${0%/*}}"
STATE_DIR="${STATE_DIR:-/data/adb/exynos9820_tune}"
SAFEMODE_FLAG="$STATE_DIR/safemode"
COUNTER_FILE="$STATE_DIR/bootcount"
CONFIG="${CONFIG:-$STATE_DIR/config.conf}"
APPLY="$MODDIR/scripts/apply.sh"
PROBE="$MODDIR/scripts/probe.sh"
ROOT="${ROOT-}"     # empty on device; set for testing

log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '')" "$*" >>"$STATE_DIR/guard.log" 2>/dev/null; }

mkdir -p "$STATE_DIR" 2>/dev/null

# ---- Safe mode: skip ALL tuning, leave device stock, tell the user ----
if [ -f "$SAFEMODE_FLAG" ]; then
    log "service: SAFE MODE active -> skipping tuning; device runs stock"
    # Surface it to the UI via a status file it can read.
    echo "safemode" > "$STATE_DIR/status"
    # Do NOT clear the counter here; user must acknowledge/fix via the UI.
    exit 0
fi

# ---- Normal path: apply saved config if one exists ----
if [ -r "$CONFIG" ]; then
    log "service: applying saved config $CONFIG"
    ROOT="$ROOT" LOG="$STATE_DIR/guard.log" sh "$APPLY" "$CONFIG"
    rc=$?
    log "service: apply.sh rc=$rc"
    echo "applied rc=$rc" > "$STATE_DIR/status"
else
    log "service: no saved config, nothing to apply"
    echo "noconfig" > "$STATE_DIR/status"
fi

# ---- Voltage margins: standalone, manual-only config. Applied as a SEPARATE
# step so a bad voltage value can never block the main tuning config, and vice
# versa. Still gated by safe mode above (we already exited if engaged).
VMARGIN_CONFIG="$STATE_DIR/vmargin.conf"
if [ -r "$VMARGIN_CONFIG" ]; then
    log "service: applying saved voltage margins $VMARGIN_CONFIG"
    ROOT="$ROOT" LOG="$STATE_DIR/guard.log" sh "$APPLY" "$VMARGIN_CONFIG"
    log "service: vmargin apply.sh rc=$?"
fi

# ---- Launch the bounded watchdog in the background ----
# It re-asserts + marks healthy, then exits. Never a permanent daemon.
ROOT="$ROOT" STATE_DIR="$STATE_DIR" CONFIG="$CONFIG" VMARGIN_CONFIG="$VMARGIN_CONFIG" MODDIR="$MODDIR" \
    sh "$MODDIR/scripts/watchdog.sh" &

exit 0
