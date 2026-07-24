# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-24

### Added

- Restore calendars/settings from a backup already saved on the server's
  filesystem (the directory the nightly backup writes to), alongside the
  existing "upload a file" option on `/ops`.
- Back up and restore news feeds, and every operator-editable `Setting`
  field (previously only 10 of 17 writable fields, and no news feeds at
  all, survived a backup/restore round-trip).
- A small version badge in the top-left corner of the kiosk dashboard,
  reflecting the running app version.
- Multi-platform (amd64 + arm64) container images, built natively on GitHub's
  `ubuntu-24.04-arm` runner instead of QEMU emulation.
- `family_dashboard.sh`, a consolidated deploy management script for the
  Ubuntu Core kiosk device.
- Test coverage for the `Event` resource, previously-untested Oban workers
  (`EventReap`, `NewsReap`, `NewsRefresh`, `WeatherDailyRefresh`, and
  `WeatherRefresh`'s `:no_location` case), and the `weather_icons` component.

### Changed

- Default the kiosk's theme to dark instead of following the system theme.
- Replace emoji weather icons with self-hosted, animated Meteocons SVGs
  (the kiosk has no emoji font).
- Harden the Containerfile: explicit `docker.io/` registry prefix, and
  `libncurses6` in the runner stage for `bin/family_dashboard remote`.

### Fixed

- Weather icons vanishing after a long-running kiosk LiveView session
  (duplicate SVG ids collided across LiveView patches).
- The `/ops` uploaded-backup file picker rendering with no visible styling,
  making it easy to miss that a file could be selected.
- Docker build failing because vendored assets (`assets/vendor`) weren't
  copied before `mix compile`.
- Multi-day all-day events only appearing on their first day, and unbounded
  multi-day event expansion at the edges of the agenda window.
- Two boot-race/config bugs found during real-device verification of the
  deploy script.
- The deploy script's `logs` command crashing under bash 3.2 (the default on
  macOS).
- Device bootstrap docs recommending `curl` where Ubuntu Core's snap
  confinement requires `scp`.

### Removed

- `install.sh`/`update.sh`, in favor of documenting the curl-based bootstrap
  directly.
- The stale `family_dashboard.env.example` file.

## [0.1.0] - 2026-07-23

Initial tagged release.
