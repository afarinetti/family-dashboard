# Deploy management script — design

## Context

The kiosk device is administered via two separate scripts,
`deploy/core/install.sh` (first-time setup) and `deploy/core/update.sh` (pull
+ recreate), both currently invoked as `./deploy/core/<script>.sh` from a
local checkout of this repo. There is no scripted `start`/`stop`/`restart`/
`status`/`logs`/`uninstall` — an operator has to know the raw `docker`
commands and the container's name (`family_dashboard`) to do any of that.

More importantly: **the device doesn't have this repo cloned onto it.**
`./deploy/core/install.sh` assumes a local checkout that doesn't actually
exist on a bare Ubuntu Core device — there's no practical way to run a script
"from the repo" without first getting the repo (or at least this file) onto
the device by some other means. The existing docs never actually addressed
how that file gets there.

This work consolidates `install.sh` + `update.sh` and adds the missing
lifecycle commands into a single, curlable Bash script, and fixes the
distribution gap by documenting a one-line `curl` bootstrap from
`raw.githubusercontent.com` — no git clone required.

## Scope

- New file: `deploy/core/family_dashboard.sh` (Bash).
- Deleted: `deploy/core/install.sh`, `deploy/core/update.sh`.
- Unchanged: `deploy/core/kiosk-setup.sh` (different concern — Wayland/Frame
  display config, not container lifecycle) and `deploy/core/family_dashboard.env.example`.
- `deploy/README.md` updated to reflect the new script and the curl-based
  bootstrap.

## Distribution

```sh
curl -fsSL https://raw.githubusercontent.com/afarinetti/family-dashboard/main/deploy/core/family_dashboard.sh -o family_dashboard.sh
chmod +x family_dashboard.sh
./family_dashboard.sh install
```

Always reflects the latest committed version on `main`. No git clone, no
dependency on any other file in the repo — this script must be fully
self-contained (it inlines the same env-file-template content `install.sh`
currently gets from the separate `family_dashboard.env.example` file, or
generates the equivalent inline — see Implementation notes).

## Commands

```
family_dashboard.sh <command> [options]

  install                First-time setup: docker snap, env file, volume, start, seed
  start                  docker start (helpful error if not installed yet)
  stop                   docker stop
  restart                docker restart
  update                 Pull latest image, recreate container, volume untouched
  status                 Running state, health, image tag/digest, uptime
  logs [-f] [--tail N]   Wrapper around docker logs (default last 100 lines, -f to follow)
  uninstall [--purge-volume] [--yes]
                         Stop + remove container; volume removal requires
                         --purge-volume AND an interactive confirmation
                         (or --yes to skip the prompt)
  help / -h / --help
```

Configuration is unchanged from the current scripts (no new persisted config
— YAGNI): `FAMILY_DASHBOARD_IMAGE`, `FAMILY_DASHBOARD_PORT`,
`FAMILY_DASHBOARD_ENV_FILE` env vars with the same defaults, same
`$HOME/family_dashboard.env` app-runtime env file (passed to `docker run
--env-file`). Every command that needs `FAMILY_DASHBOARD_IMAGE` still expects
it to be set by the caller at invocation time, exactly like today.

- `install` keeps the current idempotent shape: docker snap → env file →
  volume → pull/run → first-boot seed.
- `update` keeps the current shape: pull latest, `docker rm -f`, run again.
  Volume untouched.
- `start`/`stop`/`restart` are thin `docker <verb> family_dashboard`
  wrappers with an existence check first (clear error + "run `install`
  first" hint if the container doesn't exist).
- `status` shows: running/exited, health-check state (from the image's
  `HEALTHCHECK`), the image tag/digest actually running, and uptime — a
  friendlier `docker ps`/`docker inspect` wrapper.
- `logs` wraps `docker logs`, defaulting to `--tail 100`, with `-f` to follow.
- `uninstall` is the one new destructive command. Container removal always
  happens; volume removal is opt-in and confirmed — `--purge-volume` alone
  still prompts interactively unless `--yes` is also passed. This matches how
  the rest of the app treats data loss (e.g. `FamilyDashboard.Backup`'s
  safety-export before a restore).

## Implementation notes

- `set -euo pipefail`; a `case "$1" in ...; esac` dispatcher, one function per
  command.
- Shared helpers, factored out once instead of duplicated (today's real
  duplication between `install.sh`/`update.sh`):
  - `require_docker()` — installs/verifies the docker snap is present and
    `dockerd` is responsive.
  - `ensure_env_file()` — creates `$ENV_FILE` from the template if missing,
    generates `SECRET_KEY_BASE`, requires `SETTINGS_PASSWORD` before
    continuing.
  - `container_exists()` — used by `start`/`stop`/`restart`/`status`/`logs`
    to give a helpful error instead of a raw Docker one.
  - `run_container()` — the actual `docker run -d --name family_dashboard
    --restart always --stop-timeout 70 ...` invocation, shared by `install`
    and `update` (today this exact block is copy-pasted between the two
    files).
- Since this script can no longer assume `family_dashboard.env.example`
  exists alongside it (no repo checkout), the env-file template content
  currently in that separate file is inlined as a heredoc in
  `ensure_env_file()`. `deploy/core/family_dashboard.env.example` stays in
  the repo as human-readable reference documentation, but the script no
  longer reads it at runtime.
- Preserve existing conventions: `!!`-prefixed user-facing error messages to
  stderr, explicit `docker info` reachability check, `docker rm -f` before
  recreate to handle a stale container surviving an ungraceful reboot.

## Testing

Full Ubuntu Core arm64 device behavior (snap confinement, `--restart always`
surviving a snap-daemon restart) can't be verified from this environment.
What will be verified before calling this done:

- `shellcheck` static analysis on the finished script.
- Manual end-to-end exercise of every command (`install`, `start`, `stop`,
  `restart`, `update`, `status`, `logs`, `uninstall` with and without
  `--purge-volume`) against **plain Docker on the dev machine** — proves the
  Docker command logic is correct, but does not validate Ubuntu-Core-specific
  behavior (snap install path, confinement, autostart-after-reboot).
- The PR description will call out explicitly what was and wasn't verified.
  A real run-through on `calendar-pi` is still recommended before fully
  trusting it, the same way the multi-arch image pull was verified for real
  on that device.

## Out of scope

- Persisting `FAMILY_DASHBOARD_IMAGE`/`FAMILY_DASHBOARD_PORT` into a config
  file so they don't need re-exporting per invocation (YAGNI — not asked
  for, and would mean inventing a second config file alongside the existing
  app env file).
- Folding `kiosk-setup.sh` in (different concern, not container lifecycle).
- Any change to the actual `Containerfile`/image, CI, or the app itself.
