# FrEeRuNnErKeRnEl MoDuLe

A KernelSU WebUI module for per-cluster CPU, Mali GPU, I/O, and voltage-margin
performance tuning on Samsung Exynos9820 devices (Galaxy S10 / Note10 family).

Built with a Material 3 interface, a probe-driven engine that adapts to your
actual kernel (custom governors, real OPP tables, real sysfs layout — nothing
hardcoded), and a bootloop-safety net that automatically falls back to stock
if a saved configuration ever prevents the device from booting.

---

## Supported devices

Gated at install time (`customize.sh`) to Exynos9820-family hardware only —
the installer checks SoC platform/board properties and a codename allowlist,
and **aborts the flash** on anything else, to avoid writing 9820-specific
frequency/voltage tables to unrelated hardware.

Primary development/testing target: `beyond2lte` (Galaxy S10+).
Also works on: `beyond0lte`, `beyond1lte`, `beyondx` and `F62` (Galaxy F62)
(S10e / S10 / S10 5G), `d1`, `d1x`, `d2s`, `d2x` (Note10 family).
These share the SoC the
probe-driven design should adapt to their specific sysfs layout automatically,
but if you hit something that doesn't probe correctly, please open an issue
with your device's `sh scripts/probe.sh` output.

Requires: KernelSU or KernelSU-Next with WebUI support, and root.

---

## Features

- **Profiles** — Battery / Balanced / Performance, computed from your
  device's actual probed hardware (real OPP tables, real governor lists),
  not hardcoded values. Tap a profile, review the populated controls, Apply.
- **Advanced manual control** — per-cluster CPU governor + min/max frequency
  (big/mid/little), GPU governor + min/max clock, GPU power policy and
  highspeed-load threshold, I/O scheduler, swappiness.
- **Voltage margins** — standalone, manual-only undervolt/overvolt control
  per power rail (`-25%` to `+25%`), completely separate from profiles.
  **Read the warning below before touching this.**
- **Live vitals** — RAM/battery/CPU-temp/GPU-temp rings, per-cluster
  frequency sparkline, real-time updates.
- **Bootloop guard** — three consecutive failed boots and the module
  automatically drops into safe mode (skips all tuning) so the device can
  boot to stock. Recoverable from the UI once you're back in.
- **Config export/import** — back up your tuning as a `.txt` file, restore
  it on a fresh flash or share it with others.
- **PIN lock** — optional 4–6 digit PIN gate on the WebUI itself. This is a
  convenience lock on the interface, not a security boundary — root can
  still edit the underlying config directly.
- **Software info** — kernel version, KernelSU version, SUSFS version (when
  detectable) alongside device/status info.

### What do the CPU governors actually do?

A governor decides how the CPU scales its frequency in response to load.
Quick reference for the common ones you'll see per cluster:

- **schedutil** — the modern default on most kernels. Scales frequency based
  on actual scheduler utilization; a good balance of responsiveness and
  efficiency for daily use.
- **performance** — locks the cluster at (or very near) its maximum
  frequency at all times. Most responsive, but the highest power draw and
  heat — this is what the Performance profile leans on.
- **powersave** — the inverse: stays near the minimum frequency as much as
  possible. Best battery life, least responsive — used by the Battery
  profile.
- **ondemand** / **conservative** — older step-based governors that ramp
  frequency up/down in stages based on load, rather than schedutil's more
  continuous scaling. Still present on many kernels as fallback options.
- **blu_schedutil** — this kernel's custom tuned variant of schedutil, with
  different ramp-up/ramp-down thresholds than stock schedutil. Available on
  kernels that include it (like this one) as an alternative to the standard
  governor.
- **Other custom governors** — if your kernel exposes additional variants
  beyond the ones above, the module will list them exactly as your kernel
  names them — the dropdown only ever shows governors your specific kernel
  actually supports, never a hardcoded list.

### What do the I/O schedulers actually do?

The I/O scheduler decides the order and priority in which storage read/write
requests are processed. This kernel exposes an older-style scheduler set
rather than the newer `mq-deadline`/`kyber`/`bfq` trio found on more recent
mainline kernels:

- **noop** — no reordering at all; requests are processed in the order they
  arrive. Lowest overhead, relies entirely on the storage device itself
  (relevant for flash storage, which doesn't benefit from the seek-reducing
  reordering that spinning disks need).
- **deadline** — guarantees each request is serviced within a bounded time,
  preventing any single request from being starved indefinitely. A solid,
  predictable general-purpose choice.
- **cfq** ("Completely Fair Queuing") — divides I/O bandwidth fairly across
  all processes requesting it, avoiding any one app monopolizing storage
  access. Was the mainline default for a long time on older kernels.
- **fiops** — prioritizes by I/O *operation count* rather than bandwidth, a
  variant more tailored to flash storage where the number of operations
  matters more than raw throughput.
- **sio** ("Simple I/O") — a lightweight scheduler with minimal reordering
  overhead, aiming for lower latency at the cost of some of the fairness
  guarantees `cfq`/`deadline` provide.
- **anxiety**, **maple**, **zen** — custom schedulers specific to this
  kernel, not part of mainline Linux. Their exact tuning philosophy is the
  kernel maintainer's own; if you're unsure which to pick, `deadline` or
  `cfq` are the safest general-purpose starting points.

---

## ⚠️ Voltage margins — read this first

The Voltage Margins card (Advanced tab) lets you undervolt or overvolt each
power rail individually. This is meaningfully more dangerous than any
frequency or governor setting elsewhere in the module:

- **Aggressive negative values can cause instability, random reboots, silent
  data corruption, or hangs that don't show up immediately.** A setting can
  boot fine and then destabilize the device minutes later under load or heat.
- There is no software guardrail that can tell you *your* device's safe
  margin — it's specific to your exact silicon.
- **Change one rail at a time. Apply. Use the device normally for a while
  before touching another rail.** Don't stack multiple aggressive changes
  in one sitting.
- Voltage margins are intentionally **not** part of any profile — they are
  manual-only, so a profile switch can never silently change your voltage
  tuning underneath you.
- If your device starts behaving oddly after a voltage change, use
  **Restore rail** (or **Restore all**) immediately, or reboot — three
  consecutive failed boots triggers the automatic safe-mode fallback.

---

## Installation

1. Download the latest signed release (see **Verifying a release** below).
2. Flash via KernelSU/KernelSU-Next Manager → Modules → Install from storage.
3. Reboot.
4. Open the module's WebUI from the manager to start tuning.

---

## Verifying a release

Every release is signed. Do not flash a copy you can't verify.

**GPG fingerprint:**
```
33186B5F73941A4F5A51B76F44510930DECEE5A0
```
(`FrEeRuNnEr4EvEr <ledrew101806@gmail.com>`)

To verify a downloaded release:
```bash
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS
```
The first command should report `Good signature from "FrEeRuNnEr4EvEr ..."`
matching the fingerprint above. The second confirms the zip's contents
haven't been altered.

---

## Architecture (for contributors / the curious)

- `probe.sh` — the **only** place that decides which sysfs paths exist on
  this specific kernel and what values are legal for each. Enumerates CPU
  cpufreq policies, GPU devfreq, I/O scheduler, thermal zones, voltage
  margin rails, and software versions. Never assumes a path exists without
  checking.
- `apply.sh` — the **only** thing that writes sysfs. Re-runs `probe.sh` to
  build a fresh allowlist, validates every value against it (governor must
  be in the probed list, frequency must be a real OPP, voltage margin must
  be an integer in -25..25, etc.), and parses the config file as data
  (never sources it — a malicious or corrupted config can't execute code).
- `post-fs-data.sh` / `service.sh` / `boot-completed.sh` / `watchdog.sh` —
  the boot lifecycle. Increments a failure counter on every boot attempt;
  if it reaches 3 without a confirmed healthy boot, safe mode engages and
  all tuning is skipped until the user clears it from the UI. A bounded
  watchdog re-asserts settings for ~60s after boot (some vendor services
  rewrite GPU/thermal tables during early boot) and then exits — never a
  permanent background process.
- `webroot/index.html` — the WebUI. Talks to the shell exclusively through
  a `KSU.exec()` bridge; never validates or writes sysfs itself. Every
  Apply action stages changes for review before writing anything.

---

## License

MIT License

Copyright (c) 2026 FrEeRuNnEr4EvEr

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

## Author

FrEeRuNnEr4EvEr — [Telegram: t.me/FreeRunner4ever](https://t.me/FreeRunner4ever) ·
Help group: [t.me/FrEeRuNnEr4EvErHeLp](https://t.me/FrEeRuNnEr4EvErHeLp)
