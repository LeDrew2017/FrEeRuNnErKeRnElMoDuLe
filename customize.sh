#!/system/bin/sh
# customize.sh — sourced by the KernelSU/Magisk installer at flash time.
# Its ONE critical job: refuse to install on anything that isn't an Exynos9820
# device. Writing 9820 OPP values onto a different SoC is both a stability and a
# safety problem, so we gate hard here rather than trusting runtime checks alone.
#
# Installer environment provides: ui_print, abort, MODPATH, and getprop.

SKIPUNZIP=0

ui_print "*********************************"
ui_print " Exynos9820 Tuner"
ui_print " CPU / GPU / I/O performance tuning"
ui_print "*********************************"

# ---- Gather identity from multiple props (vendors vary) ----
DEVICE="$(getprop ro.product.device)"
[ -z "$DEVICE" ] && DEVICE="$(getprop ro.product.system.device)"
[ -z "$DEVICE" ] && DEVICE="$(getprop ro.product.vendor.device)"
BOARD="$(getprop ro.product.board)"
PLATFORM="$(getprop ro.board.platform)"
HARDWARE="$(getprop ro.hardware)"

ui_print "- Device:   $DEVICE"
ui_print "- Board:    $BOARD"
ui_print "- Platform: $PLATFORM"

# ---- Exynos9820 family: SoC-level check first (most reliable) ----
# ro.board.platform / ro.hardware report exynos9820 on these boards. Some ROMs
# report 'exynos990'/'universal9820'; accept the known variants.
is_9820=0
case "$PLATFORM$BOARD$HARDWARE" in
    *exynos9820*|*universal9820*|*9820*) is_9820=1 ;;
esac

# ---- Codename allowlist (S10 / Note10 Exynos family) as a fallback ----
# beyond0/1/2lte = S10e/S10/S10+, beyondx = S10 5G, d1/d2/d2x = Note10/Note10+.
case "$DEVICE" in
    beyond0lte|beyond1lte|beyond2lte|beyondxlte|beyondxq|\
    d1|d1xks|d2s|d2x|d2xks|d1q|d2q)
        is_9820=1 ;;
esac

if [ "$is_9820" -ne 1 ]; then
    ui_print "! This device does not appear to be Exynos9820."
    ui_print "! Refusing to install to avoid writing incorrect"
    ui_print "! frequency/voltage tables to unrelated hardware."
    abort    "! Aborted: unsupported SoC."
fi

ui_print "- Exynos9820 confirmed ($DEVICE)"

# ---- Set permissions on scripts ----
ui_print "- Setting permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
for s in post-fs-data.sh service.sh boot-completed.sh \
         scripts/probe.sh scripts/apply.sh scripts/watchdog.sh; do
    [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
done

# ---- Prepare persistent state dir ----
STATE_DIR="/data/adb/exynos9820_tune"
mkdir -p "$STATE_DIR"
# Fresh install starts with a clean guard state.
echo "0" > "$STATE_DIR/bootcount"
rm -f "$STATE_DIR/safemode"

ui_print "- Install complete."
ui_print "- Open the WebUI from the manager to tune."
