#!/system/bin/sh
# apply.sh — THE ONLY THING THAT WRITES SYSFS.
#
# Reads a staged config file (key=value, one per line), validates EVERY value
# against what probe.sh reports the device actually supports, and only then
# writes. Anything not on the probe-derived allowlist is refused. Config is
# parsed line-by-line as DATA and never sourced, so a poisoned config
# (governor=performance; rm -rf /) cannot execute — it just fails validation.
#
# Usage: ROOT=<prefix> apply.sh <config_file>
# Exit:  0 = all requested writes valid+applied; non-zero = at least one refused
#
# Every write is logged. Refusals are logged with a reason and do NOT abort the
# other valid writes (so one bad key doesn't block a whole profile) — but the
# script exits non-zero so the caller knows something was rejected.

ROOT="${ROOT-}"
CFG="${1:?usage: apply.sh <config_file>}"
# Resolve our own directory robustly. $0 may be relative depending on how the
# WebUI invokes us; fall back to the known module path.
SELF_DIR="$(dirname "$0" 2>/dev/null)"
case "$SELF_DIR" in
    ''|'.') SELF_DIR="/data/adb/modules/exynos9820_tune/scripts" ;;
esac
PROBE="$SELF_DIR/probe.sh"
[ -r "$PROBE" ] || PROBE="/data/adb/modules/exynos9820_tune/scripts/probe.sh"
LOG="${LOG:-/dev/stderr}"

log()  { printf '%s\n' "$*" >>"$LOG" 2>/dev/null || printf '%s\n' "$*" >&2; }
fail() { log "REFUSE: $*"; RC=1; }

RC=0

# ---- 1. Build the allowlist from probe ----
PROBE_OUT="$(ROOT="$ROOT" sh "$PROBE" 2>/dev/null)"

# If probe produced nothing usable, EVERY validation would fail with a
# misleading "not in []" message. Detect that up front and abort clearly.
if ! printf '%s\n' "$PROBE_OUT" | grep -q '^node\.'; then
    log "FATAL: probe returned no nodes (PROBE=$PROBE ROOT=$ROOT). Cannot validate; aborting without writes."
    exit 2
fi

# helper: pull a probe value by exact key
pv() { printf '%s\n' "$PROBE_OUT" | grep -m1 "^$1=" | cut -d= -f2-; }

# helper: is $2 a whitespace-token member of list $1 ?
in_list() {
    for _t in $1; do [ "$_t" = "$2" ] && return 0; done
    return 1
}

# helper: strict integer?
is_int() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# read a file safely (empty if missing)
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf ''; }

# helper: safe write — path must be under $ROOT/sys or /proc, must exist
safe_write() {
    _path="$1"; _val="$2"
    case "$_path" in
        "$ROOT"/sys/*|"$ROOT"/proc/*) : ;;
        *) fail "path outside allowed roots: $_path"; return 1 ;;
    esac
    case "$_path" in *..*) fail "path traversal: $_path"; return 1 ;; esac
    [ -e "$_path" ] || { fail "path missing: $_path"; return 1; }
    if printf '%s' "$_val" > "$_path" 2>/dev/null; then
        log "WROTE $_path <= $_val"
        return 0
    else
        fail "write failed: $_path <= $_val"
        return 1
    fi
}

# convert MHz back to the unit each node wants
mhz2khz() { echo $(( $1 * 1000 )); }
mhz2hz()  { echo $(( $1 * 1000000 )); }

# ---- 2. Validate + apply each config line ----
# We collect min/max per node first so we can enforce min<=max as a pair.
# Read config into positional handling without sourcing.
while IFS='=' read -r key val; do
    # skip blanks / comments
    case "$key" in ''|\#*) continue ;; esac
    # trim surrounding whitespace on key and val
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$key" ] && continue

    case "$key" in
        # ---------- CPU / GPU governor ----------
        gov-*)
            node="${key#gov-}"
            path="$(pv "node.$node.path")"
            govs="$(pv "node.$node.govs")"
            [ -z "$path" ] && { fail "unknown node: $node"; continue; }
            # GPU: dvfs_governor may echo only the current value after a prior
            # write, so probe's list can be empty. Fall back to the cached list.
            if [ "$node" = "gpu" ] && [ -z "$govs" ]; then
                _cache="${STATE_DIR:-/data/adb/exynos9820_tune}/gpu_govs.cache"
                [ -r "$_cache" ] && govs="$(cat "$_cache")"
            fi
            if ! in_list "$govs" "$val"; then
                fail "governor '$val' not in [$govs] for $node"; continue
            fi
            if [ "$node" = "gpu" ]; then
                gfile="$(pv "node.gpu.govfile")"
                [ -z "$gfile" ] && gfile="governor"
                # Read current governor. dvfs_governor may print a list + a
                # "[Current Governor] X" line; extract X. If it's already $val,
                # skip the write — some Mali drivers error when you write the
                # already-active governor.
                gcur="$(rd "$path/$gfile" | grep -i 'current governor' \
                        | sed -E 's/.*\[[Cc]urrent [Gg]overnor\][[:space:]]*//' | awk '{print $1}')"
                [ -z "$gcur" ] && gcur="$(rd "$path/$gfile" | head -1 | awk '{print $1}')"
                if [ "$gcur" = "$val" ]; then
                    log "SKIP gpu governor already $val"
                elif printf '%s' "$val" > "$path/$gfile" 2>/dev/null; then
                    log "WROTE $path/$gfile <= $val"
                else
                    # name-write failed; some kernels want the INDEX. Find val's
                    # position in the available list and write that.
                    _idx=0; _found=""
                    for _g in $govs; do
                        if [ "$_g" = "$val" ]; then _found="$_idx"; break; fi
                        _idx=$((_idx+1))
                    done
                    if [ -n "$_found" ] && printf '%s' "$_found" > "$path/$gfile" 2>/dev/null; then
                        log "WROTE $path/$gfile <= $_found (index for $val)"
                    else
                        fail "gpu governor write failed for '$val' (tried name and index)"
                    fi
                fi
            else
                safe_write "$path/scaling_governor" "$val"
            fi
            ;;

        # ---------- freq min/max (value in MHz) ----------
        *-min|*-max)
            bound="${key##*-}"          # min|max
            node="${key%-*}"            # big|mid|little|gpu
            path="$(pv "node.$node.path")"
            freqs="$(pv "node.$node.freqs")"
            [ -z "$path" ] && { fail "unknown node: $node"; continue; }
            if ! is_int "$val"; then fail "non-numeric freq '$val' for $key"; continue; fi
            if ! in_list "$freqs" "$val"; then
                fail "freq ${val}MHz not in OPP table for $node [$freqs]"; continue
            fi
            # enforce min<=max using the OTHER bound from config if present,
            # else from probe current.
            other_key="$node-$([ "$bound" = min ] && echo max || echo min)"
            other_val="$(grep -m1 "^$other_key=" "$CFG" | cut -d= -f2- | tr -d '[:space:]')"
            [ -z "$other_val" ] && other_val="$(pv "node.$node.$([ "$bound" = min ] && echo max || echo min)")"
            if is_int "$other_val"; then
                if [ "$bound" = min ] && [ "$val" -gt "$other_val" ]; then
                    fail "min ${val} > max ${other_val} for $node"; continue
                fi
                if [ "$bound" = max ] && [ "$val" -lt "$other_val" ]; then
                    fail "max ${val} < min ${other_val} for $node"; continue
                fi
            fi
            # write in the node's native unit
            if [ "$node" = "gpu" ]; then
                # Use the exact filename probe found (dvfs_min_lock, gpu_max_clock,
                # min_freq, etc.) — varies by Mali kernel. Fall back to min_freq.
                gfile="$(pv "node.gpu.${bound}file")"
                [ -z "$gfile" ] && gfile="${bound}_freq"
                # Trust the unit probe recorded from the (stable) freq table,
                # rather than re-guessing from this file's CURRENT value — that
                # can read small/zero transiently (e.g. before first write) and
                # cause a wrong-unit write. See probe.sh's GPU_UNIT.
                gunit="$(pv "node.gpu.unit")"
                case "$gunit" in
                    hz)  wval="$(mhz2hz "$val")" ;;
                    khz) wval=$(( val * 1000 )) ;;
                    *)   wval="$val" ;;
                esac
                safe_write "$path/$gfile" "$wval"
            else
                safe_write "$path/scaling_${bound}_freq" "$(mhz2khz "$val")"
            fi
            ;;

        # ---------- I/O scheduler ----------
        io-sched)
            path="$(pv "sched.path")"
            avail="$(pv "sched.avail")"
            [ -z "$path" ] && { fail "no block device probed"; continue; }
            if ! in_list "$avail" "$val"; then
                fail "scheduler '$val' not in [$avail]"; continue
            fi
            safe_write "$path/scheduler" "$val"
            ;;

        # ---------- swappiness ----------
        swappiness)
            if ! is_int "$val" || [ "$val" -gt 200 ]; then
                fail "swappiness '$val' invalid (0-200)"; continue
            fi
            safe_write "$ROOT/proc/sys/vm/swappiness" "$val"
            ;;

        # ---------- GPU highspeed load threshold (percent 0-100) ----------
        gpu-highspeed-load)
            gpath="$(pv "node.gpu.path")"
            [ -z "$gpath" ] && { fail "no gpu node"; continue; }
            if ! is_int "$val" || [ "$val" -gt 100 ]; then
                fail "highspeed_load '$val' invalid (0-100)"; continue
            fi
            safe_write "$gpath/highspeed_load" "$val"
            ;;

        # ---------- GPU highspeed clock (must be a real GPU OPP, MHz) ----------
        gpu-highspeed-clock)
            gpath="$(pv "node.gpu.path")"
            gfreqs="$(pv "node.gpu.freqs")"
            [ -z "$gpath" ] && { fail "no gpu node"; continue; }
            if ! is_int "$val"; then fail "highspeed_clock '$val' non-numeric"; continue; fi
            if ! in_list "$gfreqs" "$val"; then
                fail "highspeed_clock ${val}MHz not in GPU OPP table"; continue
            fi
            # Trust probe's recorded unit (see GPU_UNIT in probe.sh) rather than
            # re-guessing from this file's current value, which can read small
            # or zero and cause a wrong-unit write — same class of bug fixed
            # for min/max lock above.
            gunit="$(pv "node.gpu.unit")"
            case "$gunit" in
                hz)  safe_write "$gpath/highspeed_clock" "$(( val * 1000000 ))" ;;
                khz) safe_write "$gpath/highspeed_clock" "$(( val * 1000 ))" ;;
                *)   safe_write "$gpath/highspeed_clock" "$val" ;;
            esac
            ;;

        # ---------- GPU power policy ----------
        gpu-power-policy)
            gpath="$(pv "node.gpu.path")"
            [ -z "$gpath" ] && { fail "no gpu node"; continue; }
            # validate against the bracketed list in power_policy
            pp="$(rd "$gpath/power_policy" | tr ' ' '\n' | tr -d '[]' | grep -v '^$' | tr '\n' ' ')"
            if ! in_list "$pp" "$val"; then
                fail "power_policy '$val' not in [$pp]"; continue
            fi
            safe_write "$gpath/power_policy" "$val"
            ;;

        # ---------- Voltage margin (undervolt/overvolt) — one rail at a time.
        # Standalone, manual-only; never bundled with profiles. Strict bounds:
        # integer, -25..+25 inclusive. Rail must be one probe actually found
        # (i.e. the kernel really exposes that file) — never trust the key
        # alone to imply the path exists.
        vmargin-*)
            rail="${key#vmargin-}"
            case "$rail" in
                lit|mid|big|g3d|mif|mfc|npu|aud|cam|cp|disp|int|intcam|iva|score) : ;;
                *) fail "unknown voltage rail: $rail"; continue ;;
            esac
            # value must be an integer, optionally signed, exactly -25..25
            case "$val" in
                -[0-9]|-1[0-9]|-2[0-5]|[0-9]|1[0-9]|2[0-5]) : ;;
                *) fail "vmargin $rail: '$val' out of range (-25..25)"; continue ;;
            esac
            vpath="$ROOT/sys/power/percent_margin/${rail}_margin_percent"
            # confirm probe actually saw this rail (defense in depth: don't
            # trust a hardcoded path guess even though we just built it above)
            probed_val="$(pv "vmargin.$rail")"
            if [ -z "$probed_val" ] && [ ! -r "$vpath" ]; then
                fail "vmargin $rail: rail not present on this kernel"; continue
            fi
            safe_write "$vpath" "$val"
            ;;

        # ---------- ignore known non-sysfs prefs ----------
        __profile|theme|wallpaper|profile) : ;;

        # ---------- anything else: refuse ----------
        *) fail "unknown key: $key" ;;
    esac
done < "$CFG"

log "apply.sh done rc=$RC"
exit $RC
