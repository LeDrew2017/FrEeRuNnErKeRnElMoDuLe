#!/system/bin/sh
# make_mock.sh — build a fake exynos9820 sysfs tree under $ROOT for testing
# probe.sh and apply.sh without a real device. Mirrors the real beyond2lte
# layout: 3 CPU policies (little=policy0, mid=policy4, big=policy6), Mali
# devfreq GPU, block device queue, and thermal zones.
set -eu
ROOT="${1:?usage: make_mock.sh <root>}"

rm -rf "$ROOT"
mkdir -p "$ROOT"

# ---- CPU cpufreq policies ----
# policy0 = little (A55), policy4 = mid (A75), policy6 = big (M4)
make_policy() {
    d="$ROOT/sys/devices/system/cpu/cpufreq/$1"
    mkdir -p "$d"
    echo "$2" > "$d/scaling_available_frequencies"
    echo "schedutil performance powersave" > "$d/scaling_available_governors"
    echo "schedutil" > "$d/scaling_governor"
    echo "$3" > "$d/scaling_min_freq"
    echo "$4" > "$d/scaling_max_freq"
    echo "$4" > "$d/scaling_cur_freq"
    echo "$3" > "$d/cpuinfo_min_freq"
    echo "$4" > "$d/cpuinfo_max_freq"
}
# freqs in kHz (as real sysfs uses)
make_policy policy0 "299000 455000 715000 949000 1287000 1690000 1794000" 299000 1794000
make_policy policy4 "377000 546000 858000 1352000 1560000 1794000 2002000 2314000" 377000 2314000
make_policy policy6 "455000 715000 1105000 1430000 1794000 2184000 2496000 2730000" 455000 2730000

# ---- GPU (Mali devfreq) ----
GPU="$ROOT/sys/devices/platform/13900000.mali"
mkdir -p "$GPU"
echo "377 385 455 546 645 700 754 897" > "$GPU/dvfs_table"          # MHz
echo "simple_ondemand performance powersave userspace" > "$GPU/available_governors"
echo "simple_ondemand" > "$GPU/governor"
echo "377000000" > "$GPU/min_freq"   # devfreq uses Hz
echo "897000000" > "$GPU/max_freq"
echo "700000000" > "$GPU/cur_freq"

# ---- Block device I/O scheduler ----
BLK="$ROOT/sys/block/sda/queue"
mkdir -p "$BLK"
echo "[mq-deadline] kyber bfq none" > "$BLK/scheduler"
echo "128" > "$BLK/read_ahead_kb"
echo "128" > "$BLK/nr_requests"

# ---- Thermal zones ----
# zone0 = big cluster, zone1 = gpu (typical exynos mapping varies; probe reads type)
mk_zone() { d="$ROOT/sys/class/thermal/$1"; mkdir -p "$d"; echo "$2" > "$d/type"; echo "$3" > "$d/temp"; }
mk_zone thermal_zone0 "BIG"  42000   # millidegrees C
mk_zone thermal_zone1 "G3D"  38000
mk_zone thermal_zone2 "LITTLE" 39000
mk_zone thermal_zone3 "battery" 31000

# ---- VM knobs ----
mkdir -p "$ROOT/proc/sys/vm"
echo "100" > "$ROOT/proc/sys/vm/swappiness"

# ---- device codename (build prop stand-in) ----
mkdir -p "$ROOT/etc"
echo "beyond2lte" > "$ROOT/etc/codename"

echo "mock tree built at $ROOT"
