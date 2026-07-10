#!/system/bin/sh
# post-fs-data.sh — runs EARLY in boot (before the tuning is applied).
# Owns the bootloop guard. This is the safety keystone of the whole module.
#
# How the guard works:
#   - Each boot we increment a counter file. If the previous boot(s) never
#     reached "healthy" (system_server up), the counter is still > 0 from last
#     time and keeps climbing.
#   - If the counter reaches THRESHOLD, we assume our tuning is bootlooping the
#     device, so we drop into SAFE MODE: create a flag that service.sh checks
#     and, if present, skips ALL tuning. The device boots stock.
#   - A separate late process (marked healthy by service.sh's watchdog once the
#     UI/boot is confirmed good) resets the counter to 0. So a clean boot always
#     zeroes it; only boots that die before "healthy" accumulate.
#
# Nothing here writes any performance sysfs. It only manages guard state.

MODDIR="${MODDIR:-${0%/*}}"
# Persist guard state in the module's own data dir (survives reboots, wiped on
# module uninstall). Overridable for testing.
STATE_DIR="${STATE_DIR:-/data/adb/exynos9820_tune}"
COUNTER_FILE="$STATE_DIR/bootcount"
SAFEMODE_FLAG="$STATE_DIR/safemode"
THRESHOLD="${BOOTLOOP_THRESHOLD:-3}"

mkdir -p "$STATE_DIR" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '')" "$*" >>"$STATE_DIR/guard.log" 2>/dev/null; }

# read current count (default 0)
count=0
[ -r "$COUNTER_FILE" ] && count="$(cat "$COUNTER_FILE" 2>/dev/null)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# Increment for this boot attempt.
count=$((count + 1))
echo "$count" > "$COUNTER_FILE"
log "post-fs-data: boot attempt count=$count (threshold=$THRESHOLD)"

if [ "$count" -ge "$THRESHOLD" ]; then
    # We've had THRESHOLD consecutive boots that never confirmed healthy.
    # Assume our tuning is the cause. Engage safe mode.
    : > "$SAFEMODE_FLAG"
    log "post-fs-data: THRESHOLD reached -> SAFE MODE engaged, tuning will be skipped"
fi

# ---- Capture the STOCK baseline (governors + scheduler) ONCE ----
# This runs before service.sh applies any saved tuning, so the values here are
# the kernel/ROM defaults. The WebUI reads this file for its Reset target.
# We only write it if it doesn't already exist (first clean boot after install),
# so a later tuned boot can't overwrite the true stock values.
STOCK="$STATE_DIR/stock_defaults.conf"
if [ ! -f "$STOCK" ] && [ ! -f "$SAFEMODE_FLAG" ]; then
    {
        for pol in /sys/devices/system/cpu/cpufreq/policy*; do
            [ -r "$pol/scaling_governor" ] || continue
            pn="$(basename "$pol")"
            echo "cpugov.$pn=$(cat "$pol/scaling_governor" 2>/dev/null)"
        done
        for g in /sys/devices/platform/*.mali; do
            [ -d "$g" ] || continue
            if [ -r "$g/dvfs_governor" ]; then
                # extract the "[Current Governor] X" token if present, else first word
                gv="$(grep -i 'current governor' "$g/dvfs_governor" 2>/dev/null \
                      | sed -E 's/.*\[[Cc]urrent [Gg]overnor\][[:space:]]*//' | awk '{print $1}')"
                [ -z "$gv" ] && gv="$(head -1 "$g/dvfs_governor" 2>/dev/null | awk '{print $1}')"
                echo "gpugov=$gv"
            fi
        done
        for blk in /sys/block/sda/queue /sys/block/mmcblk0/queue; do
            [ -r "$blk/scheduler" ] || continue
            # current elevator is the [bracketed] one
            echo "sched=$(tr ' ' '\n' < "$blk/scheduler" | grep '^\[' | tr -d '[]')"
            break
        done
    } > "$STOCK" 2>/dev/null
    log "post-fs-data: captured stock defaults -> $STOCK"
fi

exit 0
