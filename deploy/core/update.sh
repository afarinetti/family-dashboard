#!/bin/sh
# Update family_dashboard to the latest published image on an Ubuntu Core
# kiosk device. See deploy/README.md for the full runbook.
#
# The `family_dashboard_data` volume (SQLite DB + Oban job state + backups)
# is untouched by this script — only the container is replaced. Migrations
# re-run automatically at boot (see FamilyDashboard.Application).
set -eu

IMAGE="${FAMILY_DASHBOARD_IMAGE:-ghcr.io/CHANGE_ME/family_dashboard:latest}"
CONTAINER_NAME="family_dashboard"
VOLUME_NAME="family_dashboard_data"
ENV_FILE="${FAMILY_DASHBOARD_ENV_FILE:-$HOME/family_dashboard.env}"
PORT="${FAMILY_DASHBOARD_PORT:-4000}"

if [ "$IMAGE" = "ghcr.io/CHANGE_ME/family_dashboard:latest" ]; then
  echo "!! Set FAMILY_DASHBOARD_IMAGE (or edit this script) to your real ghcr.io image path." >&2
  exit 1
fi
[ -f "$ENV_FILE" ] || { echo "!! Env file not found at $ENV_FILE — run install.sh first." >&2; exit 1; }

echo "==> Pulling $IMAGE..."
docker pull "$IMAGE"

echo "==> Recreating $CONTAINER_NAME..."
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

echo "==> Updated. Tail logs with: docker logs -f $CONTAINER_NAME"
