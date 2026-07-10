#!/system/bin/sh
# probe.sh — enumerate the device's tunable sysfs nodes and their allowed
# values. Emits key=value lines on stdout (parsed as DATA by the WebUI and by
# apply.sh — never sourced). On a real device run with ROOT="". For testing,
# ROOT points at a mock tree.
#
# Design: this is the ONLY place that decides which paths exist and what values
# are legal. apply.sh re-runs the same enumeration to build its allowlist, so
# the two can never disagree about what's writable.
#
# Output contract (all freqs normalized to MHz for the UI):
#   codename=beyond2lte
#   node.<id>.path=<absolute sysfs dir>
#   node.<id>.govs=<space-separated available governors>   (cpu/gpu only)
#   node.<id>.gov=<current governor>
#   node.<id>.freqs=<space-separated available freqs MHz>
#   node.<id>.min=<current min MHz>  node.<id>.max=<current max MHz>
#   sched.path=<block queue dir>  sched.avail=<...>  sched.cur=<...>
#   thermal.<label>=<path>
# Lines are only emitted for nodes that actually exist.

ROOT="${ROOT-}"
CPU="$ROOT/sys/devices/system/cpu/cpufreq"

emit() { printf '%s\n' "$1"; }

# read first token / whole line safely; empty if missing
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf ''; }

# strip brackets from "[mq-deadline] kyber" -> current elevator only
current_bracket() { echo "$1" | tr ' ' '\n' | grep '^\[' | tr -d '[]'; }
strip_brackets()  { echo "$1" | tr -d '[]'; }

# kHz -> MHz (integer)
khz2mhz() { [ -n "$1" ] && echo $(( $1 / 1000 )) || echo ""; }
# Hz -> MHz
hz2mhz()  { [ -n "$1" ] && echo $(( $1 / 1000000 )) || echo ""; }

# ---- codename ----
# Trust the LIVE system property first — it reflects the actual running
# device, whereas a file like /etc/codename can be a stale artifact left
# over from a shared ROM build tree (e.g. baked in from one target device
# and never overwritten per-variant), which would misidentify the device
# on every other variant flashed from the same base.
CN="$(getprop ro.product.device 2>/dev/null)"
[ -z "$CN" ] && CN="$(rd "$ROOT/etc/codename")"
[ -z "$CN" ] && CN="unknown"
emit "codename=$CN"

# ---- CPU clusters ----
# Map policy dirs to logical ids by ascending policy number:
# lowest = little, highest = big, middle = mid (works for 3-cluster 9820).
if [ -d "$CPU" ]; then
    # `sort -V` is GNU-only and can be missing/behave inconsistently under
    # Android's toolbox/toybox sh depending on invocation context (this caused
    # CPU nodes to silently vanish from probe output in some environments even
    # though the same script worked fine from an interactive shell). Extract
    # just the numeric suffix and sort numerically instead — portable, and
    # policy numbers are always plain integers so this is equivalent.
    POLICIES="$(ls -d "$CPU"/policy* 2>/dev/null \
        | sed -E 's#.*/policy([0-9]+)$#\1 &#' \
        | sort -n -k1,1 \
        | cut -d' ' -f2-)"
    n=0; total=0
    for p in $POLICIES; do total=$((total+1)); done
    for p in $POLICIES; do
        case "$n" in
            0) id="little" ;;
            *) if [ "$n" -eq $((total-1)) ]; then id="big"; else id="mid"; fi ;;
        esac
        n=$((n+1))
        [ -d "$p" ] || continue
        # available freqs (kHz) -> MHz, ascending
        raw="$(rd "$p/scaling_available_frequencies")"
        mhz=""
        for f in $raw; do mhz="$mhz $(khz2mhz "$f")"; done
        mhz="$(echo "$mhz" | tr ' ' '\n' | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ *$//')"
        emit "node.$id.path=$p"
        emit "node.$id.govs=$(rd "$p/scaling_available_governors")"
        emit "node.$id.gov=$(rd "$p/scaling_governor")"
        emit "node.$id.freqs=$mhz"
        emit "node.$id.min=$(khz2mhz "$(rd "$p/scaling_min_freq")")"
        emit "node.$id.max=$(khz2mhz "$(rd "$p/scaling_max_freq")")"
    done
fi

# ---- GPU (Mali) — layout varies a LOT across Exynos Mali kernels ----
GPU=""
for cand in \
    "$ROOT"/sys/devices/platform/*.mali \
    "$ROOT"/sys/class/devfreq/*.mali \
    "$ROOT"/sys/class/misc/mali0/device ; do
    [ -d "$cand" ] && { GPU="$cand"; break; }
done
if [ -n "$GPU" ] && [ -d "$GPU" ]; then
    emit "node.gpu.path=$GPU"

    # --- available frequency table: try several known filenames ---
    graw=""
    for f in dvfs_table gpu_available_frequencies available_frequencies \
             gpu_freq_table freq_table clock_info; do
        [ -r "$GPU/$f" ] && { graw="$(rd "$GPU/$f")"; break; }
    done
    # Some kernels list the table under a dvfs/ subdir.
    [ -z "$graw" ] && [ -r "$GPU/dvfs/dvfs_table" ] && graw="$(rd "$GPU/dvfs/dvfs_table")"

    # Extract just integers (some tables are "freq volt" pairs or have labels).
    gnums="$(echo "$graw" | tr ' \t' '\n\n' | grep -E '^[0-9]+$')"

    # --- unit auto-detect: normalize whatever unit to MHz ---
    # Detect from the FREQ TABLE (a stable, one-time reference) rather than a
    # live current-value file, which can read small/zero transiently and cause
    # apply.sh to guess the wrong unit on a write. Record the verdict as a fact
    # so apply.sh trusts it instead of re-detecting from a possibly-stale read.
    gmax_tok="$(echo "$gnums" | sort -n | tail -1)"
    GPU_UNIT="mhz"
    if [ -n "$gmax_tok" ]; then
        if   [ "$gmax_tok" -ge 100000000 ] 2>/dev/null; then GPU_UNIT="hz"
        elif [ "$gmax_tok" -ge 100000 ]    2>/dev/null; then GPU_UNIT="khz"
        fi
    fi
    to_mhz() {  # $1 = raw file content, possibly dirty (extra tokens, non-numeric)
        # Extract just the FIRST integer token — some kernels report min/max
        # lock files as "current/limit" pairs or with trailing whitespace/units
        # rather than a bare number (seen on beyond0lte's dvfs_min_lock).
        # Trusting the raw string as-is here previously let garbage like
        # "572000 / 572000" or a sentinel -1 pass straight through to the UI.
        clean="$(echo "$1" | grep -oE '[0-9]+' | head -1)"
        [ -z "$clean" ] && { echo ""; return; }
        if   [ "$clean" -ge 100000000 ] 2>/dev/null; then echo $(( clean / 1000000 ))   # Hz
        elif [ "$clean" -ge 100000 ]    2>/dev/null; then echo $(( clean / 1000 ))      # kHz
        else echo "$clean"; fi                                                          # MHz
    }
    gmhz=""
    for v in $gnums; do gmhz="$gmhz $(to_mhz "$v")"; done
    gmhz="$(echo "$gmhz" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//')"
    emit "node.gpu.freqs=$gmhz"
    emit "node.gpu.unit=$GPU_UNIT"

    # --- current min/max clock: many possible filenames ---
    gmin_raw=""; gmax_raw=""
    for f in min_freq gpu_min_clock dvfs_min_lock gpu_dvfs_min_lock \
             scaling_min_freq gpu_min_freq; do
        [ -r "$GPU/$f" ] && { gmin_raw="$(rd "$GPU/$f")"; GPU_MIN_FILE="$f"; break; }
    done
    for f in max_freq gpu_max_clock dvfs_max_lock gpu_dvfs_max_lock \
             scaling_max_freq gpu_max_freq; do
        [ -r "$GPU/$f" ] && { gmax_raw="$(rd "$GPU/$f")"; GPU_MAX_FILE="$f"; break; }
    done
    gmin_mhz="$(to_mhz "$gmin_raw")"
    gmax_mhz="$(to_mhz "$gmax_raw")"
    # Sanity check: min/max must be a plausible frequency actually within the
    # device's own probed OPP range. A sentinel value like -1 (captured as a
    # bare "1" after digit-extraction) or any reading outside the real table
    # is not trustworthy — fall back to the table's own bounds instead of
    # exposing a value the UI would otherwise treat as real (e.g. the -1/572000
    # anomaly seen on beyond0lte's dvfs_min_lock/dvfs_max_lock).
    gtable_lo="$(echo "$gmhz" | tr ' ' '\n' | sort -n | head -1)"
    gtable_hi="$(echo "$gmhz" | tr ' ' '\n' | sort -n | tail -1)"
    if [ -z "$gmin_mhz" ] || [ "$gmin_mhz" -lt "${gtable_lo:-0}" ] 2>/dev/null || [ "$gmin_mhz" -gt "${gtable_hi:-999999}" ] 2>/dev/null; then
        gmin_mhz="$gtable_lo"
    fi
    if [ -z "$gmax_mhz" ] || [ "$gmax_mhz" -lt "${gtable_lo:-0}" ] 2>/dev/null || [ "$gmax_mhz" -gt "${gtable_hi:-999999}" ] 2>/dev/null; then
        gmax_mhz="$gtable_hi"
    fi
    emit "node.gpu.min=$gmin_mhz"
    emit "node.gpu.max=$gmax_mhz"
    # expose which files we found so apply.sh writes the right ones
    [ -n "${GPU_MIN_FILE:-}" ] && emit "node.gpu.minfile=$GPU_MIN_FILE"
    [ -n "${GPU_MAX_FILE:-}" ] && emit "node.gpu.maxfile=$GPU_MAX_FILE"

    # --- governor: Exynos Mali dvfs_governor format varies. This kernel uses:
    #       "Default Interactive Joint Static Booster Dynamic
    #        [Current Governor] Interactive"
    #     i.e. a space-separated available list, then a line labeling the current
    #     one. Also handle the "[N] Name" per-line bracketed variant and a plain
    #     single value.
    ggov=""; ggovs=""; GPU_GOV_FILE=""
    for f in dvfs_governor governor gpu_governor scaling_governor; do
        [ -r "$GPU/$f" ] && { GPU_GOV_RAW="$(rd "$GPU/$f")"; GPU_GOV_FILE="$f"; break; }
    done
    if [ -n "${GPU_GOV_FILE:-}" ]; then
        # Is there a "[Current Governor] X" marker line?
        if echo "$GPU_GOV_RAW" | grep -qi 'current governor'; then
            # current = token after the "[Current Governor]" label
            ggov="$(echo "$GPU_GOV_RAW" | grep -i 'current governor' \
                    | sed -E 's/.*\[[Cc]urrent [Gg]overnor\][[:space:]]*//' \
                    | awk '{print $1}')"
            # available = the line(s) WITHOUT the current-governor marker,
            # flattened to space-separated tokens.
            ggovs="$(echo "$GPU_GOV_RAW" | grep -vi 'current governor' \
                    | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        elif echo "$GPU_GOV_RAW" | grep -q '^\[[0-9]'; then
            # "[0] Default" per-line variant
            ggovs="$(echo "$GPU_GOV_RAW" | sed -E 's/^\[?[0-9]*\]?[[:space:]]*//' | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
            ggov="$(echo "$GPU_GOV_RAW" | grep '\[' | head -1 | sed -E 's/^\[?[0-9]*\]?[[:space:]]*//')"
        else
            # plain single value
            ggov="$(echo "$GPU_GOV_RAW" | head -1 | awk '{print $1}')"
        fi
    fi
    # explicit available-governors file overrides if present
    for f in dvfs_available_governors available_governors \
             gpu_available_governors scaling_available_governors; do
        [ -r "$GPU/$f" ] && { ggovs="$(rd "$GPU/$f")"; break; }
    done
    emit "node.gpu.gov=$ggov"
    emit "node.gpu.govs=$ggovs"
    [ -n "${GPU_GOV_FILE:-}" ] && emit "node.gpu.govfile=$GPU_GOV_FILE"
    # Cache the available governor list to a stable file. On many Mali kernels
    # `dvfs_governor` only shows the full list until it's written to, after which
    # it echoes just the current value. apply.sh reads this cache so it can still
    # validate governor names after a prior write.
    if [ -n "$ggovs" ]; then
        _cache="${STATE_DIR:-/data/adb/exynos9820_tune}/gpu_govs.cache"
        mkdir -p "$(dirname "$_cache")" 2>/dev/null
        # only (over)write the cache when we actually have the full list (>1 entry)
        _cnt=0; for _g in $ggovs; do _cnt=$((_cnt+1)); done
        if [ "$_cnt" -gt 1 ] || [ ! -f "$_cache" ]; then
            printf '%s\n' "$ggovs" > "$_cache" 2>/dev/null
        fi
    fi
    # live current clock file (for Home tab). This Mali exposes `clock`.
    for f in clock cur_freq scaling_cur_freq gpu_clock; do
        [ -r "$GPU/$f" ] && { emit "node.gpu.curfile=$GPU/$f"; break; }
    done
    # power policy (optional extra tunable)
    [ -r "$GPU/power_policy" ] && emit "node.gpu.power_policy=$(rd "$GPU/power_policy")"
    # Mali highspeed threshold tunables (gaming responsiveness): the clock the
    # GPU jumps to under load, and the load% that triggers it.
    [ -r "$GPU/highspeed_clock" ] && emit "node.gpu.highspeed_clock=$(rd "$GPU/highspeed_clock")"
    [ -r "$GPU/highspeed_load" ]  && emit "node.gpu.highspeed_load=$(rd "$GPU/highspeed_load")"
fi

# ---- Voltage margins (undervolt/overvolt per rail) ----
# Each rail is its own file under /sys/power/percent_margin/. Standalone,
# manual-only controls — never touched by profiles. Only emit rails that
# actually exist on this kernel; a missing file means the WebUI hides that
# rail's row rather than showing a dead control.
VMARGIN="$ROOT/sys/power/percent_margin"
if [ -d "$VMARGIN" ]; then
    for rail in lit mid big g3d mif mfc npu aud cam cp disp int intcam iva score; do
        f="$VMARGIN/${rail}_margin_percent"
        [ -r "$f" ] && emit "vmargin.$rail=$(rd "$f")"
    done
fi
for blk in "$ROOT"/sys/block/sda/queue "$ROOT"/sys/block/mmcblk0/queue; do
    if [ -r "$blk/scheduler" ]; then
        sc="$(rd "$blk/scheduler")"
        emit "sched.path=$blk"
        emit "sched.avail=$(strip_brackets "$sc")"
        emit "sched.cur=$(current_bracket "$sc")"
        break
    fi
done

# ---- thermal zones (emit by type) ----
for z in "$ROOT"/sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    t="$(rd "$z/type")"
    [ -n "$t" ] && emit "thermal.$t=$z"
done

# ---- vm ----
[ -r "$ROOT/proc/sys/vm/swappiness" ] && emit "vm.swappiness=$(rd "$ROOT/proc/sys/vm/swappiness")"

# ---- Versions: kernel / KernelSU / SUSFS (informational, Info tab only) ----
# Kernel version: prefer the FULL uname -r string (matches /proc/version's
# release field exactly), which on custom kernels includes the build's own
# branding/tag (e.g. "4.14.356-FrEeRuNnErKeRnEl-v3.8+") — genuinely useful
# info, not just a bare number.
kver="$(uname -r 2>/dev/null)"
[ -z "$kver" ] && kver="$(rd "$ROOT/proc/version" | awk '{print $3}')"
[ -n "$kver" ] && emit "ver.kernel=$kver"

# KernelSU version: /data/adb/ksu/ typically has no plain "version" file (it
# has bin/lib/log/module_configs instead), so check a getprop first, then
# fall back to whatever KernelSU-Next itself exposes via its own binary if
# present, then finally look for a recognizable tag in /proc/version.
ksuver="$(getprop ro.kernelsu.version 2>/dev/null)"
if [ -z "$ksuver" ] && command -v ksud >/dev/null 2>&1; then
    ksuver="$(ksud -V 2>/dev/null || ksud --version 2>/dev/null)"
fi
if [ -z "$ksuver" ]; then
    ksuver="$(rd "$ROOT/proc/version" | grep -oE '[Kk]ernel[Ss][Uu][A-Za-z0-9._+-]*' | head -1)"
fi
[ -n "$ksuver" ] && emit "ver.kernelsu=$ksuver"

# SUSFS version: the real, correct command is `ksu_susfs show version` — an
# earlier guess (-v) only printed the tool's usage banner, which is worse
# than showing nothing. Only accept output that actually looks like a
# version string; anything else (usage text, errors) is discarded.
susfsver=""
if command -v ksu_susfs >/dev/null 2>&1; then
    raw="$(ksu_susfs show version 2>/dev/null | head -1)"
    # sanity check: a real version line is short and doesn't start with
    # "usage" — never trust the tool's help text as if it were data.
    case "$raw" in
        ''|usage*|Usage*) : ;;
        *) [ "${#raw}" -le 64 ] && susfsver="$raw" ;;
    esac
fi
if [ -z "$susfsver" ]; then
    for f in /data/adb/ksu/susfs_version /data/adb/susfs_version; do
        [ -r "$f" ] && { susfsver="$(rd "$f")"; break; }
    done
fi
if [ -z "$susfsver" ]; then
    susfsver="$(rd "$ROOT/proc/version" | grep -oE 'susfs[A-Za-z0-9._+-]*' | head -1)"
fi
[ -n "$susfsver" ] && emit "ver.susfs=$susfsver"

exit 0
