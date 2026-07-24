# Deploy Management Script Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `deploy/core/install.sh` and `deploy/core/update.sh` with a single, self-contained Bash script (`deploy/core/family_dashboard.sh`) that handles the full container lifecycle (install/start/stop/restart/update/status/logs/uninstall) and can be curled onto a bare Ubuntu Core device with no git clone.

**Architecture:** One Bash file with a `case`-based command dispatcher, one `cmd_*` function per subcommand, and small shared helpers (`require_docker`, `ensure_env_file`, `container_exists`, `run_container`) factored out of what's currently duplicated between `install.sh` and `update.sh`.

**Tech Stack:** Bash (`set -euo pipefail`), Docker CLI, `shellcheck` for static analysis.

## Global Constraints

- Script must be fully self-contained — no dependency on any other file in the repo at runtime (see design doc: the device won't have this repo cloned).
- Config stays env-var driven exactly as today: `FAMILY_DASHBOARD_IMAGE`, `FAMILY_DASHBOARD_PORT` (default `4000`), `FAMILY_DASHBOARD_ENV_FILE` (default `$HOME/family_dashboard.env`). No new persisted config file.
- Container name stays `family_dashboard`, volume name stays `family_dashboard_data` (matching the existing volume already in use on the real device — renaming would orphan it).
- `uninstall`'s volume removal must require `--purge-volume` AND an interactive "yes" confirmation, unless `--yes` is also passed.
- Preserve existing UX conventions: `==>` progress messages, `!!`-prefixed errors to stderr.

---

### Task 1: Write the complete `family_dashboard.sh` script

**Files:**
- Create: `deploy/core/family_dashboard.sh`

**Interfaces:**
- Produces: `main()` entry point invoked as `main "$@"` at the bottom of the file; subcommands `install|start|stop|restart|update|status|logs|uninstall|help`; shared helpers `require_image()`, `require_docker()`, `ensure_env_file()`, `container_exists()`, `require_existing_container()`, `run_container()`.

There's no automated test framework for shell scripts in this repo (no `bats`/`shunit2`), so this task's "does it work" check is a syntax check (`bash -n`, the closest thing to a fast compile-time check) — Task 2 adds static analysis (`shellcheck`) and Task 3 does real behavioral verification against Docker.

- [ ] **Step 1: Write the script**

Create `deploy/core/family_dashboard.sh` with this exact content:

```bash
#!/usr/bin/env bash
# Manages family_dashboard as a container on an Ubuntu Core kiosk device.
# See deploy/README.md for the full runbook.
#
# Self-contained — curl this one file onto a bare device, no git clone needed:
#
#   curl -fsSL https://raw.githubusercontent.com/afarinetti/family-dashboard/main/deploy/core/family_dashboard.sh -o family_dashboard.sh
#   chmod +x family_dashboard.sh
#   ./family_dashboard.sh install
set -euo pipefail

IMAGE="${FAMILY_DASHBOARD_IMAGE:-ghcr.io/CHANGE_ME/family_dashboard:latest}"
CONTAINER_NAME="family_dashboard"
VOLUME_NAME="family_dashboard_data"
ENV_FILE="${FAMILY_DASHBOARD_ENV_FILE:-$HOME/family_dashboard.env}"
PORT="${FAMILY_DASHBOARD_PORT:-4000}"

usage() {
  cat <<'EOF'
Usage: family_dashboard.sh <command> [options]

Commands:
  install                 First-time setup: docker snap, env file, volume, start, seed
  start                   Start the container
  stop                    Stop the container
  restart                 Restart the container
  update                  Pull the latest image and recreate the container
  status                  Show running state, health, and image info
  logs [-f] [--tail N]    Show container logs (default: last 100 lines)
  uninstall [--purge-volume] [--yes]
                          Stop and remove the container (and optionally the
                          data volume, with confirmation)
  help                    Show this help

Environment variables:
  FAMILY_DASHBOARD_IMAGE      Image to pull/run (required for install/update)
  FAMILY_DASHBOARD_PORT       Host port (default: 4000)
  FAMILY_DASHBOARD_ENV_FILE   Path to the app's runtime env file
                               (default: $HOME/family_dashboard.env)
EOF
}

require_image() {
  if [ "$IMAGE" = "ghcr.io/CHANGE_ME/family_dashboard:latest" ]; then
    echo "!! Set FAMILY_DASHBOARD_IMAGE to your real ghcr.io image path." >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "==> Installing the docker snap..."
    sudo snap install docker
    # dockerd needs a moment to come up on first install.
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
  fi
  docker info >/dev/null 2>&1 || { echo "!! dockerd isn't responding — check 'snap logs docker'." >&2; exit 1; }
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "==> No env file at $ENV_FILE — creating from template."
    cat > "$ENV_FILE" <<'TEMPLATE'
# Runtime environment for the family_dashboard container on the kiosk device.
#
# These are read by config/runtime.exs inside the `config_env() == :prod`
# block — see that file for exactly how each var is used.

# --- Required ----------------------------------------------------------------

# Signs/encrypts session cookies. This script generates one for you
# automatically if left blank.
SECRET_KEY_BASE=

# Shared-password gate for the /admin, /oban, and /ops areas (calendars,
# location, scheduling, backups). Pick a real password before going live.
SETTINGS_USERNAME=family
SETTINGS_PASSWORD=

# --- Optional ------------------------------------------------------------

# Hostname used for URL generation (cosmetic only — this deploy serves plain
# http with check_origin disabled; see config/runtime.exs). Set to the
# device's hostname or LAN IP if you want generated links/QR-style URLs to be
# accurate. Defaults to "example.com" if unset.
PHX_HOST=

# HTTP port the app listens on inside the container (defaults to 4000). Only
# change this if you also set FAMILY_DASHBOARD_PORT when running this script.
PORT=4000

# SQLite connection pool size (defaults to 10). A single kiosk browser + Oban
# background jobs rarely need more than the default.
POOL_SIZE=

# Weather provider: "xweather" (default) or "openweather".
WEATHER_PROVIDER=xweather

# Xweather (https://www.xweather.com) client credentials — the default
# provider. Leave unset to run without weather (the dashboard degrades
# gracefully — see FamilyDashboard.Heartbeat).
XWEATHER_CLIENT_ID=
XWEATHER_CLIENT_SECRET=

# OpenWeatherMap API key (free tier) — only used if WEATHER_PROVIDER=openweather.
WEATHER_API_KEY=

# DATABASE_PATH and BACKUP_DIR are set inside the Containerfile
# (/data/family_dashboard.db, /data/backups) to match the /data volume mount
# this script uses — do not override these unless you also change the volume
# mount.
TEMPLATE
    chmod 600 "$ENV_FILE"
    echo "    Edit $ENV_FILE (SETTINGS_PASSWORD at minimum) and re-run this script."
    echo "    (SECRET_KEY_BASE will be auto-generated below if you leave it blank.)"
  fi

  if ! grep -q '^SECRET_KEY_BASE=.\+' "$ENV_FILE"; then
    local generated
    generated=$(openssl rand -base64 64 | tr -d '\n')
    sed -i.bak "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${generated}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    echo "==> Generated SECRET_KEY_BASE in $ENV_FILE."
  fi

  if ! grep -q '^SETTINGS_PASSWORD=.\+' "$ENV_FILE"; then
    echo "!! SETTINGS_PASSWORD is blank in $ENV_FILE — set a real password before continuing." >&2
    exit 1
  fi
}

container_exists() {
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

require_existing_container() {
  container_exists || { echo "!! No '$CONTAINER_NAME' container found — run 'family_dashboard.sh install' first." >&2; exit 1; }
}

# Removes any lingering container of the same name — handles both a
# deliberate re-run and a stale container left behind by an ungraceful
# power-cut reboot — then starts a fresh one from the current $IMAGE.
run_container() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    --stop-timeout 70 \
    -p "${PORT}:${PORT}" \
    -e "PORT=${PORT}" \
    -v "${VOLUME_NAME}:/data" \
    --env-file "$ENV_FILE" \
    "$IMAGE"
}

cmd_install() {
  require_image
  require_docker
  ensure_env_file

  echo "==> Ensuring the $VOLUME_NAME volume exists..."
  docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME"

  echo "==> Pulling $IMAGE..."
  docker pull "$IMAGE"

  echo "==> Starting $CONTAINER_NAME..."
  run_container

  # Creates the singleton `Setting` row (location/greeting/refresh intervals)
  # so weather works out of the box. Releases don't run priv/repo/seeds.exs
  # automatically, and /ops has no create-path for a missing Setting — so
  # this is required, not optional, on a genuinely fresh volume. Safe to
  # re-run: seeds.exs checks for an existing row before inserting.
  echo "==> Waiting for the app to come up..."
  for _ in $(seq 1 30); do
    docker exec "$CONTAINER_NAME" bin/family_dashboard pid >/dev/null 2>&1 && break
    sleep 1
  done

  echo "==> Seeding the default Setting row (if none exists)..."
  docker exec "$CONTAINER_NAME" bin/family_dashboard rpc \
    'Code.eval_file(Path.join(:code.priv_dir(:family_dashboard), "repo/seeds.exs"))'

  echo "==> Done. Visit http://localhost:${PORT}/ (or http://<device-ip>:${PORT}/ from the LAN)."
  echo "    Edit the seeded location/greeting at http://localhost:${PORT}/admin"
  echo "    Next: run kiosk-setup.sh to put the dashboard on the wall display."
}

cmd_start() {
  require_existing_container
  docker start "$CONTAINER_NAME"
  echo "==> Started $CONTAINER_NAME."
}

cmd_stop() {
  require_existing_container
  docker stop "$CONTAINER_NAME"
  echo "==> Stopped $CONTAINER_NAME."
}

cmd_restart() {
  require_existing_container
  docker restart "$CONTAINER_NAME"
  echo "==> Restarted $CONTAINER_NAME."
}

cmd_update() {
  require_image
  require_docker
  [ -f "$ENV_FILE" ] || { echo "!! Env file not found at $ENV_FILE — run 'family_dashboard.sh install' first." >&2; exit 1; }

  echo "==> Pulling $IMAGE..."
  docker pull "$IMAGE"

  echo "==> Recreating $CONTAINER_NAME..."
  run_container

  echo "==> Updated. Tail logs with: $0 logs -f"
}

cmd_status() {
  require_existing_container

  local state health image started
  state=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$CONTAINER_NAME")
  image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
  started=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME")

  echo "Container: $CONTAINER_NAME"
  echo "  State:   $state"
  echo "  Health:  $health"
  echo "  Image:   $image"
  echo "  Started: $started"
}

cmd_logs() {
  require_existing_container

  local tail_value="100"
  local -a extra_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -f)
        extra_args+=(-f)
        shift
        ;;
      --tail)
        [ $# -ge 2 ] || { echo "!! --tail requires a value" >&2; exit 1; }
        tail_value="$2"
        shift 2
        ;;
      *)
        echo "!! Unknown logs option: $1" >&2
        exit 1
        ;;
    esac
  done

  docker logs "${extra_args[@]}" --tail "$tail_value" "$CONTAINER_NAME"
}

cmd_uninstall() {
  local purge_volume="false"
  local assume_yes="false"

  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-volume) purge_volume="true"; shift ;;
      --yes) assume_yes="true"; shift ;;
      *)
        echo "!! Unknown uninstall option: $1" >&2
        exit 1
        ;;
    esac
  done

  if container_exists; then
    echo "==> Stopping and removing $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    echo "==> No $CONTAINER_NAME container found — nothing to remove."
  fi

  if [ "$purge_volume" = "true" ]; then
    if [ "$assume_yes" != "true" ]; then
      printf '!! This will permanently delete the %s volume (the SQLite database, Oban queue, and backups). Type "yes" to confirm: ' "$VOLUME_NAME"
      read -r confirmation
      if [ "$confirmation" != "yes" ]; then
        echo "==> Aborted. Volume not removed."
        exit 1
      fi
    fi

    if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
      docker volume rm "$VOLUME_NAME"
      echo "==> Removed volume $VOLUME_NAME."
    else
      echo "==> No $VOLUME_NAME volume found — nothing to purge."
    fi
  fi
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }

  local cmd="$1"
  shift

  case "$cmd" in
    install) cmd_install ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    update) cmd_update ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *)
      echo "!! Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
```

- [ ] **Step 2: Make it executable and syntax-check it**

Run:
```sh
chmod +x deploy/core/family_dashboard.sh
bash -n deploy/core/family_dashboard.sh
```
Expected: no output (silent success = valid syntax).

- [ ] **Step 3: Sanity-check `help` runs before anything else is wired up**

Run:
```sh
./deploy/core/family_dashboard.sh help
./deploy/core/family_dashboard.sh
echo "exit code: $?"
./deploy/core/family_dashboard.sh bogus-command
echo "exit code: $?"
```
Expected: `help` and no-args both print the usage text; no-args exits `1`; `bogus-command` prints `!! Unknown command: bogus-command` to stderr, then usage, then exits `1`.

- [ ] **Step 4: Commit**

```sh
git add deploy/core/family_dashboard.sh
git commit -m "$(cat <<'EOF'
Add consolidated family_dashboard.sh deploy management script

Replaces install.sh + update.sh (removed in a later commit) with one
self-contained, curlable script covering the full container lifecycle:
install, start, stop, restart, update, status, logs, uninstall.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Static analysis with shellcheck

**Files:**
- Modify: `deploy/core/family_dashboard.sh` (only if shellcheck finds real issues)

**Interfaces:**
- Consumes: the complete script from Task 1.

- [ ] **Step 1: Check for shellcheck, install if missing**

Run:
```sh
command -v shellcheck || brew install shellcheck
```
Expected: either an existing path is printed, or Homebrew installs it successfully.

- [ ] **Step 2: Run shellcheck against the script**

Run:
```sh
shellcheck deploy/core/family_dashboard.sh
```
Expected: no warnings. The script was written avoiding shellcheck's most common gotchas (quoted expansions throughout, arrays instead of word-splitting for `cmd_logs`'s optional flags, `local` for function-scoped vars), so this should pass clean. If it doesn't:

- [ ] **Step 3: Fix any reported issues**

For each shellcheck warning, apply its suggested fix directly in `deploy/core/family_dashboard.sh`, then re-run `shellcheck deploy/core/family_dashboard.sh` until clean.

- [ ] **Step 4: Commit (only if Step 3 made changes)**

```sh
git add deploy/core/family_dashboard.sh
git commit -m "$(cat <<'EOF'
Fix shellcheck findings in family_dashboard.sh

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

If Step 2 was already clean, skip this commit — nothing changed.

---

### Task 3: Manual end-to-end verification against real Docker

**Files:** none (verification only, no code changes expected)

**Interfaces:**
- Consumes: the complete, shellcheck-clean script from Tasks 1–2.

This exercises every command against **plain Docker on the dev machine** (not the Ubuntu Core snap, not the device) using the real, already-published `ghcr.io/afarinetti/family_dashboard:latest` image. This proves the Docker command logic is correct. It does **not** validate Ubuntu-Core-specific behavior (snap install path, confinement, autostart-after-reboot) — that still needs a real run-through on `calendar-pi`, same as the multi-arch image pull was verified for real on that device.

Use a non-default port and a scratch env file so this can't collide with a local `mix phx.server` (which also binds 4000) or anything else already running.

- [ ] **Step 1: Confirm no pre-existing `family_dashboard` container or volume**

Run:
```sh
docker ps -a --filter name=family_dashboard
docker volume ls --filter name=family_dashboard_data
```
Expected: both empty. If either already has an entry, stop and ask before proceeding — don't touch something that might be real data.

- [ ] **Step 2: `install`**

Run:
```sh
export FAMILY_DASHBOARD_IMAGE=ghcr.io/afarinetti/family_dashboard:latest
export FAMILY_DASHBOARD_PORT=4001
export FAMILY_DASHBOARD_ENV_FILE=/tmp/family_dashboard_verify.env
./deploy/core/family_dashboard.sh install
```
This will stop with `!! SETTINGS_PASSWORD is blank...` on the first run (expected — matches the documented flow). Edit the generated file and re-run:
```sh
sed -i '' 's/^SETTINGS_PASSWORD=$/SETTINGS_PASSWORD=verify-me/' /tmp/family_dashboard_verify.env
./deploy/core/family_dashboard.sh install
```
Expected: pulls the image, creates the `family_dashboard_data` volume, starts the container, waits for boot, seeds the `Setting` row, and prints the "Done. Visit http://localhost:4001/" message with no errors.

- [ ] **Step 3: Verify it's actually serving**

Run:
```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4001/
```
Expected: `200`.

- [ ] **Step 4: `status`**

Run:
```sh
./deploy/core/family_dashboard.sh status
```
Expected: `State: running`, `Health: healthy` (may print `starting` if run within the Containerfile's 15s `--start-period` — re-run after a few seconds if so), correct image name, a `Started` timestamp.

- [ ] **Step 5: `logs`**

Run:
```sh
./deploy/core/family_dashboard.sh logs --tail 20
```
Expected: the last 20 lines of container output, no errors, no hang (confirms `-f` was NOT passed through when not requested).

- [ ] **Step 6: `stop` / `start`**

Run:
```sh
./deploy/core/family_dashboard.sh stop
./deploy/core/family_dashboard.sh status
./deploy/core/family_dashboard.sh start
./deploy/core/family_dashboard.sh status
```
Expected: after `stop`, `status` shows `State: exited`; after `start`, back to `running`.

- [ ] **Step 7: `restart`**

Run:
```sh
./deploy/core/family_dashboard.sh restart
./deploy/core/family_dashboard.sh status
```
Expected: `State: running`, and a newer `Started` timestamp than Step 4.

- [ ] **Step 8: `update`**

Run:
```sh
./deploy/core/family_dashboard.sh update
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4001/
```
Expected: pulls (likely "Image is up to date" since nothing changed), recreates the container, `curl` still returns `200` — proving the volume survived the recreate (if the `Setting` seed hadn't persisted, first boot after `update` would behave like a fresh install).

- [ ] **Step 9: `uninstall` without `--purge-volume`**

Run:
```sh
./deploy/core/family_dashboard.sh uninstall
docker ps -a --filter name=family_dashboard
docker volume ls --filter name=family_dashboard_data
```
Expected: container removed, but the volume still listed.

- [ ] **Step 10: Reinstall, then `uninstall --purge-volume` with the confirmation prompt**

Run:
```sh
./deploy/core/family_dashboard.sh install
./deploy/core/family_dashboard.sh uninstall --purge-volume
```
When prompted, type something other than `yes` (e.g. `n`) first and confirm it aborts without deleting:
```sh
docker volume ls --filter name=family_dashboard_data
```
Expected: volume still present, script exited `1`. Then re-run and actually confirm:
```sh
./deploy/core/family_dashboard.sh uninstall --purge-volume
# type: yes
docker volume ls --filter name=family_dashboard_data
```
Expected: volume gone.

- [ ] **Step 11: `uninstall --purge-volume --yes` skips the prompt**

Run:
```sh
export FAMILY_DASHBOARD_ENV_FILE=/tmp/family_dashboard_verify.env
./deploy/core/family_dashboard.sh install
./deploy/core/family_dashboard.sh uninstall --purge-volume --yes
docker volume ls --filter name=family_dashboard_data
```
Expected: no prompt shown, volume removed immediately.

- [ ] **Step 12: Clean up the scratch env file**

Run:
```sh
rm -f /tmp/family_dashboard_verify.env
unset FAMILY_DASHBOARD_IMAGE FAMILY_DASHBOARD_PORT FAMILY_DASHBOARD_ENV_FILE
```

No commit for this task — verification only, no files changed (unless Steps above surfaced a bug, in which case fix it in `family_dashboard.sh`, re-run the failing step to confirm, and commit with a message describing what was wrong).

---

### Task 4: Remove the old scripts and update the docs

**Files:**
- Delete: `deploy/core/install.sh`
- Delete: `deploy/core/update.sh`
- Modify: `deploy/README.md`

**Interfaces:** none (docs + deletion only).

- [ ] **Step 1: Delete the superseded scripts**

```sh
git rm deploy/core/install.sh deploy/core/update.sh
```

- [ ] **Step 2: Update `deploy/README.md`'s "On the device: install Docker + the app" section**

Find this block (currently under `### 2. On the device: install Docker + the app`):

```markdown
```sh
export FAMILY_DASHBOARD_IMAGE=ghcr.io/<your-org>/family_dashboard:latest
./deploy/core/install.sh
```

This installs the `docker` snap, creates the `family_dashboard_data` volume,
prompts you (via the generated `~/family_dashboard.env`) to set
`SETTINGS_PASSWORD` (and optionally weather API keys), generates
`SECRET_KEY_BASE` for you, and starts the container with
`--restart always`. It finishes by seeding the singleton `Setting` row (see
**First-boot seed** below) and printing the URL to check.
```

Replace it with:

```markdown
```sh
curl -fsSL https://raw.githubusercontent.com/afarinetti/family-dashboard/main/deploy/core/family_dashboard.sh -o family_dashboard.sh
chmod +x family_dashboard.sh
export FAMILY_DASHBOARD_IMAGE=ghcr.io/<your-org>/family_dashboard:latest
./family_dashboard.sh install
```

No git clone required — `family_dashboard.sh` is fully self-contained. It
installs the `docker` snap, creates the `family_dashboard_data` volume,
prompts you (via the generated `~/family_dashboard.env`) to set
`SETTINGS_PASSWORD` (and optionally weather API keys), generates
`SECRET_KEY_BASE` for you, and starts the container with
`--restart always`. It finishes by seeding the singleton `Setting` row (see
**First-boot seed** below) and printing the URL to check.

Once installed, `family_dashboard.sh start|stop|restart|status|logs|update|uninstall`
covers the rest of the lifecycle — run `./family_dashboard.sh help` for the
full list.
```

- [ ] **Step 3: Update the "Updating" section**

Find:

```markdown
## Updating

After CI publishes a new image:

```sh
export FAMILY_DASHBOARD_IMAGE=ghcr.io/<your-org>/family_dashboard:latest
./deploy/core/update.sh
```

This pulls `latest` and recreates the container. The `family_dashboard_data`
volume is untouched; migrations re-run automatically at boot (see
`FamilyDashboard.Application` — the `Ecto.Migrator` child runs whenever
`RELEASE_NAME` is set, which `mix release` sets automatically).
```

Replace with:

```markdown
## Updating

After CI publishes a new image:

```sh
export FAMILY_DASHBOARD_IMAGE=ghcr.io/<your-org>/family_dashboard:latest
./family_dashboard.sh update
```

This pulls `latest` and recreates the container. The `family_dashboard_data`
volume is untouched; migrations re-run automatically at boot (see
`FamilyDashboard.Application` — the `Ecto.Migrator` child runs whenever
`RELEASE_NAME` is set, which `mix release` sets automatically).
```

- [ ] **Step 4: Update the "First-boot seed" manual re-run command**

Find (still references `docker exec` directly, which is fine to leave as raw Docker for a one-off manual command, but check the surrounding prose doesn't still say "install.sh runs the idempotent seed automatically" without qualification — verify it still reads correctly):

```markdown
row only comes from that seed file... `install.sh` runs
the idempotent seed automatically; to re-run it manually:
```

Replace `install.sh` with `family_dashboard.sh install` in that sentence.

- [ ] **Step 5: Grep for any remaining references to the deleted scripts**

Run:
```sh
grep -rn "install\.sh\|update\.sh" deploy/README.md CLAUDE.md README.md
```
Expected: no output (or only unrelated matches — read any hits and fix them the same way as Steps 2–4).

- [ ] **Step 6: Verify the doc renders sensibly**

Run:
```sh
grep -n "family_dashboard.sh" deploy/README.md
```
Expected: several matches, all consistent with the new script (no leftover `install.sh`/`update.sh` paths).

- [ ] **Step 7: Commit**

```sh
git add deploy/core/install.sh deploy/core/update.sh deploy/README.md
git commit -m "$(cat <<'EOF'
Remove install.sh/update.sh, document the curl-based bootstrap

deploy/core/family_dashboard.sh (added in a prior commit) now covers
everything these two scripts did, plus start/stop/restart/status/logs/
uninstall. Documents the new one-line curl bootstrap in deploy/README.md,
since the device was never actually able to run "./deploy/core/install.sh"
without the whole repo checked out.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** distribution (curl bootstrap) → Task 4 Step 2; all 8 commands → Task 1; shared-helper deduplication → Task 1 (`run_container`, `require_docker`, `ensure_env_file`, `container_exists`); destructive-action safety on `uninstall` → Task 1's `cmd_uninstall` + verified in Task 3 Steps 9–11; shellcheck → Task 2; manual Docker verification with explicit call-out of what's NOT verified (Core-specific behavior) → Task 3; old scripts removed + docs updated → Task 4. No spec section without a task.
- **Placeholder scan:** none — every step has literal commands/code, no "TBD" or "similar to above."
- **Type/name consistency:** `CONTAINER_NAME`/`VOLUME_NAME`/`ENV_FILE`/`IMAGE`/`PORT` are defined once at the top of Task 1's script and used identically by name throughout every `cmd_*` function; `cmd_logs`'s `extra_args`/`tail_value` locals don't leak into other functions; the `main()` dispatcher's command names match `usage()`'s documented command list exactly.
