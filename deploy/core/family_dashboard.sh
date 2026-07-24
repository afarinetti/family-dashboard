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
#
# Must be a non-blank integer, not left empty: config/runtime.exs does
# `String.to_integer(System.get_env("POOL_SIZE") || "10")`, and Docker's
# --env-file sets a bare `POOL_SIZE=` to an empty string rather than leaving
# it unset, so `System.get_env` returns "" (truthy in Elixir) and the release
# crashes in `String.to_integer("")` during boot. Leave this line as-is
# (POOL_SIZE=10) rather than blanking it out.
POOL_SIZE=10

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
  # `bin/family_dashboard pid` only proves the BEAM node itself is up — it
  # returns success while the release is still running migrations and before
  # the app's supervision tree (and Repo) has started, which made the seed
  # step below race against a "could not lookup Ecto repo" error on a fresh
  # volume. Poll for the Repo process specifically instead.
  echo "==> Waiting for the app to come up..."
  for _ in $(seq 1 30); do
    docker exec "$CONTAINER_NAME" bin/family_dashboard rpc \
      'if !Process.whereis(FamilyDashboard.Repo), do: raise("not up")' >/dev/null 2>&1 && break
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

  # "${extra_args[@]}" alone throws "unbound variable" under `set -u` on
  # bash 3.2 (macOS's default /bin/bash) when the array is empty — fixed in
  # bash 4.4+, but this script has to tolerate older bash too. The
  # ${arr[@]+"${arr[@]}"} idiom expands to nothing when the array is unset
  # or empty, on every bash version.
  docker logs "${extra_args[@]+"${extra_args[@]}"}" --tail "$tail_value" "$CONTAINER_NAME"
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
