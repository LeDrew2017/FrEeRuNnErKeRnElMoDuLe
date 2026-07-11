# Changelog

All notable changes to FrEeRuNnErKeRnEl MoDuLe are documented here.

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
