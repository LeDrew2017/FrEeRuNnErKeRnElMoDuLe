# Changelog

All notable changes to FrEeRuNnErKeRnEl MoDuLe are documented here.

## v1.0.1

- Expanded Exynos9820 Support: Resolved issues found during extended testing across the broader device family (including beyond0lte alongside beyond2lte).
- Accurate Device Identification: Fixed a bug where the module could report the wrong codename. Device identity is now read directly from the live ro.product.device system property, preventing the use of stale or absent file paths.
- Resolved "Hardware Not Detected" Error: Fixed the root cause of false failures in the WebUI. The probe.sh script now always exits cleanly upon success, rather than letting ambiguous internal checks (like an empty SUSFS check) dictate the exit status.
- GPU Frequency Validation: Added checks for malformed or out-of-range GPU min/max clocks. The module now verifies these against the device's real supported frequency range and corrects them automatically.
- Corrected Device List: Fixed an incorrect device codename for the Note10 5G (d1x) and added support for the Galaxy F62 (f62), which was previously missing from the install-time check.
- UI Enhancement: Added a module icon.

## v1.0.0 — Initial release

First public release.

- Battery / Balanced / Performance profiles, computed from the device's
  actual probed hardware (real OPP tables, real governor lists).
- Manual control: per-cluster CPU governor + min/max frequency, GPU
  governor + min/max clock + power policy + highspeed-load threshold, I/O
  scheduler, swappiness.
- Voltage margin control per power rail (-25% to +25%), standalone and
  manual-only — never touched by profiles.
- Live vitals: RAM / battery / CPU temp / GPU temp rings, per-cluster
  frequency sparkline.
- Bootloop guard: three consecutive failed boots automatically engages safe
  mode (skips all tuning) so the device can boot to stock; recoverable from
  the UI.
- Config export/import as a `.txt` file.
- Optional 4–6 digit PIN lock on the WebUI.
- Kernel / KernelSU / SUSFS version display in the Info tab.
- Install-time device gate: refuses to flash on non-Exynos9820 hardware.
