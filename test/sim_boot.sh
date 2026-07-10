#!/bin/bash
# sim_boot.sh — simulate boot cycles against the mock tree to prove the
# bootloop guard, using the REAL boot flow:
#   post-fs-data.sh  -> increments counter, trips safe mode at threshold
#   service.sh       -> applies config (unless safe mode), spawns watchdog
#   boot-completed.sh-> ONLY runs on a healthy boot; clears counter
set -u
MOD="/home/claude/exynos-tuner"
ROOT=/tmp/mock
STATE=/tmp/guardstate
export ROOT STATE_DIR="$STATE"
export BOOTLOOP_THRESHOLD=3
export REASSERT_TIMES=2 REASSERT_INTERVAL=0
export CONFIG="$STATE/config.conf"

reset_all() {
    bash "$MOD/test/make_mock.sh" "$ROOT" >/dev/null
    rm -rf "$STATE"; mkdir -p "$STATE"
    cat > "$CONFIG" <<'EOF'
gov-big=performance
big-max=2496
io-sched=bfq
EOF
}

count() { cat "$STATE/bootcount" 2>/dev/null || echo "(none)"; }
status(){ cat "$STATE/status" 2>/dev/null || echo "(none)"; }
safemode(){ [ -f "$STATE/safemode" ] && echo YES || echo no; }

# one boot. healthy=1 => boot-completed.sh runs (Android confirmed boot).
do_boot() {
    local healthy="$1"
    MODDIR="$MOD" sh "$MOD/post-fs-data.sh"
    MODDIR="$MOD" sh "$MOD/service.sh"
    MODDIR="$MOD" sh "$MOD/scripts/watchdog.sh"   # inline for determinism
    if [ "$healthy" = 1 ]; then
        MODDIR="$MOD" sh "$MOD/boot-completed.sh"
    fi
    wait 2>/dev/null
}

echo "================ SCENARIO 1: healthy boot ================"
reset_all
echo "before: count=$(count) safemode=$(safemode)"
do_boot 1
echo "after:  count=$(count) status=$(status) safemode=$(safemode)"
echo "big gov: $(cat $ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor) (want performance)"
echo "EXPECT: count=0, status=healthy, safemode=no, governor=performance"
echo

echo "================ SCENARIO 2: 3 failed boots -> safe mode ================"
reset_all
for b in 1 2 3; do
    do_boot 0
    echo "failed boot $b: count=$(count) safemode=$(safemode) status=$(status)"
done
echo "EXPECT: count 1,2,3 ; safemode=YES at boot 3"
echo

echo "================ SCENARIO 3: safe mode skips tuning ================"
bash "$MOD/test/make_mock.sh" "$ROOT" >/dev/null
gov_before=$(cat $ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor)
do_boot 1
gov_after=$(cat $ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor)
echo "status=$(status) (want safemode) safemode=$(safemode)"
echo "gov before=$gov_before after=$gov_after (want unchanged=schedutil)"
echo "EXPECT: status=safemode, governor NOT changed"
echo

echo "================ SCENARIO 4: recovery ================"
rm -f "$STATE/safemode"; echo "0" > "$STATE/bootcount"
bash "$MOD/test/make_mock.sh" "$ROOT" >/dev/null
do_boot 1
echo "count=$(count) status=$(status) safemode=$(safemode)"
echo "big gov: $(cat $ROOT/sys/devices/system/cpu/cpufreq/policy6/scaling_governor) (want performance)"
echo "EXPECT: count=0, status=healthy, tuning re-applied"
