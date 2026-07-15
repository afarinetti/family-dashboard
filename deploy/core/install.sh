#!/bin/sh
# One-time install of family_dashboard on an Ubuntu Core kiosk device.
#
# Run this on the device itself (not in CI). See deploy/README.md for the
# full runbook, including why this uses the Docker snap rather than Podman,
# and why persistence uses a named Docker volume rather than a host
# bind-mount (arbitrary host paths fail *silently* under Ubuntu Core's snap
# confinement — see that doc before changing this).
#
# Idempotent: safe to re-run (e.g. after editing family_dashboard.env).
set -eu

IMAGE="${FAMILY_DASHBOARD_IMAGE:-ghcr.io/CHANGE_ME/family_dashboard:latest}"
CONTAINER_NAME="family_dashboard"
VOLUME_NAME="family_dashboard_data"
ENV_FILE="${FAMILY_DASHBOARD_ENV_FILE:-$HOME/family_dashboard.env}"
PORT="${FAMILY_DASHBOARD_PORT:-4000}"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "==> family_dashboard install (image: $IMAGE)"

if [ "$IMAGE" = "ghcr.io/CHANGE_ME/family_dashboard:latest" ]; then
  echo "!! Set FAMILY_DASHBOARD_IMAGE (or edit this script) to your real ghcr.io image path." >&2
  exit 1
fi

# --- 1. Docker snap ----------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing the docker snap..."
  sudo snap install docker
  # dockerd needs a moment to come up on first install.
  for i in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi
docker info >/dev/null 2>&1 || { echo "!! dockerd isn't responding — check 'snap logs docker'." >&2; exit 1; }

# --- 2. Env file ---------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  echo "==> No env file at $ENV_FILE — creating from template."
  cp "$script_dir/family_dashboard.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    Edit $ENV_FILE (SETTINGS_PASSWORD at minimum) and re-run this script."
  echo "    (SECRET_KEY_BASE will be auto-generated below if you leave it blank.)"
fi

# Auto-generate SECRET_KEY_BASE if the operator left it blank.
if ! grep -q '^SECRET_KEY_BASE=.\+' "$ENV_FILE"; then
  generated=$(openssl rand -base64 64 | tr -d '\n')
  # BSD sed (Ubuntu Core busybox/coreutils) vs GNU sed both accept this form.
  sed -i.bak "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${generated}|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
  echo "==> Generated SECRET_KEY_BASE in $ENV_FILE."
fi

if ! grep -q '^SETTINGS_PASSWORD=.\+' "$ENV_FILE"; then
  echo "!! SETTINGS_PASSWORD is blank in $ENV_FILE — set a real password before continuing." >&2
  exit 1
fi

# --- 3. Persistent volume --------------------------------------------------
docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME"

# --- 4. Pull + (re)create the container --------------------------------------
echo "==> Pulling $IMAGE..."
docker pull "$IMAGE"

# Remove any lingering container of the same name — handles both a deliberate
# re-run of this script and a stale container left behind by an ungraceful
# power-cut reboot (a named container can survive a crash even though it
# isn't running, which would otherwise make `docker run --name` fail).
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "==> Starting $CONTAINER_NAME..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  --stop-timeout 70 \
  -p "${PORT}:${PORT}" \
  -e "PORT=${PORT}" \
  -v "${VOLUME_NAME}:/data" \
  --env-file "$ENV_FILE" \
  "$IMAGE"

# --- 5. First-boot seed (idempotent) -----------------------------------------
# Creates the singleton `Setting` row (location/greeting/refresh intervals) so
# weather works out of the box. Releases don't run `priv/repo/seeds.exs`
# automatically, and /ops has no create-path for a missing Setting (its form
# only renders once one exists) — so this step is required, not optional, on
# a genuinely fresh volume. Safe to re-run: seeds.exs checks for an existing
# row before inserting.
echo "==> Waiting for the app to come up..."
for i in $(seq 1 30); do
  docker exec "$CONTAINER_NAME" bin/family_dashboard pid >/dev/null 2>&1 && break
  sleep 1
done

echo "==> Seeding the default Setting row (if none exists)..."
docker exec "$CONTAINER_NAME" bin/family_dashboard rpc \
  'Code.eval_file(Path.join(:code.priv_dir(:family_dashboard), "repo/seeds.exs"))'

echo "==> Done. Visit http://localhost:${PORT}/ (or http://<device-ip>:${PORT}/ from the LAN)."
echo "    Edit the seeded location/greeting at http://localhost:${PORT}/admin"
echo "    Next: run deploy/core/kiosk-setup.sh to put the dashboard on the wall display."
