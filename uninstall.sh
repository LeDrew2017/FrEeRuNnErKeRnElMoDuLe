#!/system/bin/sh
# uninstall.sh — runs when the module is removed. Clean up our persistent state
# so nothing is left behind (guard counters, safe-mode flag, saved config, logs).
STATE_DIR="/data/adb/exynos9820_tune"
rm -rf "$STATE_DIR" 2>/dev/null
exit 0
