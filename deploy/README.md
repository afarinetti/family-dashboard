# Deploying family_dashboard to the kiosk

This runbook covers deploying family_dashboard as a container to an **Ubuntu Core**
kiosk device (a fixed 27" wall monitor in portrait, 1080×1920), with the image
built by GitHub Actions and published to GitHub Container Registry (ghcr.io).

## Why this shape

- **Ubuntu Core** is an immutable, snap-only OS — no `apt`, read-only root,
  only strictly-confined snaps. That rules out the usual Podman/Quadlet/host
  bind-mount playbook: strict confinement breaks rootless Podman (hides the
  setuid `newuidmap`/`newgidmap`) and Quadlet (needs to install a systemd
  generator under `/usr/lib/systemd`, which the immutable root forbids). The
  only Quadlet-capable Podman snap is deliberately *classic*, so it can't
  install on Core at all.
- Instead we use the Canonical-maintained, strictly-confined **`docker`
  snap**. `dockerd` runs as a snap daemon and auto-starts on boot; a container
  created with `docker run -d --restart always` is revived by dockerd on
  every boot — no extra wrapper snap needed for a single appliance.
- **Persistence uses a named Docker volume, not a host bind-mount.**
  Strictly-confined container snaps on Core can only bind-mount from a
  hardcoded allow-list (`/home`, `/media`) — an arbitrary path like
  `/var/lib/...` **fails silently** (the mount "succeeds" but the container
  sees an empty directory, and your data vanishes on every recreate). A named
  volume avoids this trap entirely: it lives under the docker snap's own
  writable area and survives `docker rm`/image updates.
- The OCI image itself is engine-agnostic — it builds and runs the same under
  Docker or Podman. Only the on-device run/autostart layer is Docker-specific.

## One-time setup

### 1. GitHub Actions → ghcr.io

No setup needed — `.github/workflows/ci.yml` authenticates to `ghcr.io` with the
repo's built-in `GITHUB_TOKEN` (scoped via the workflow's `packages: write`
permission), so there are no PAT/repo secrets to configure.

Push to `main` (or a `v*` tag) — the `build` job builds the image with `docker
buildx` and pushes `ghcr.io/<owner>/family_dashboard:latest` (plus a commit-SHA
tag, and a matching tag on git tags; tag pushes also attach a release tarball
to a GitHub Release). Set the package visibility to **Public** on GitHub
(Packages tab) so the device can pull without authenticating — the image
carries no secrets; those are injected at container runtime.

### 2. On the device: install Docker + the app

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

Verify: `docker logs family_dashboard` should show migrations running, then
Bandit listening. `curl http://localhost:4000/` should return 200 with no
redirect (this deploy serves plain http — see `config/runtime.exs`).

### 3. On the device: put the dashboard on the wall

```sh
./deploy/core/kiosk-setup.sh
```

Installs `ubuntu-frame` + `wpe-webkit-mir-kiosk`, points the kiosk browser at
`http://localhost:4000`, and prints the exact `snap set ubuntu-frame
display=...` command for portrait rotation (you'll need to read `snap logs
ubuntu-frame` once to find your monitor's output name, e.g. `HDMI-A-1`).

### 4. Reboot and confirm autostart

Reboot the device. `dockerd`, the `family_dashboard` container, `ubuntu-frame`,
and `wpe-webkit-mir-kiosk` should all come back automatically and the wall
display should show the dashboard within a minute or so of boot.

**This reboot is the go/no-go check.** If the container does *not* come back
after a reboot (rare, but `--restart always` behavior under confined-snap
dockerd hasn't been exhaustively verified), the fallback is to wrap the
`docker run` in a small strict "application snap" with a `daemon: simple`
service — see the comment in `deploy/core/install.sh`'s history / ask for
help; this is more setup than most single-device deployments need.

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

## First-boot seed

Releases don't run `priv/repo/seeds.exs` automatically, and the singleton
`Setting` row (location, greeting, refresh intervals — read every minute by
`FamilyDashboard.Heartbeat`) only comes from that seed file. Without it the
app still boots fine (the heartbeat has hardcoded fallback intervals), but
weather stays blank and the greeting is empty. `/ops` **cannot** create this
row — its form only renders once a `Setting` already exists. `install.sh` runs
the idempotent seed automatically; to re-run it manually:

```sh
docker exec family_dashboard bin/family_dashboard rpc \
  'Code.eval_file(Path.join(:code.priv_dir(:family_dashboard), "repo/seeds.exs"))'
```

After that, edit the real location/greeting at `http://localhost:4000/admin`.

## Configuring calendars and news feeds

Not deploy-time config — these are runtime, DB-backed settings:

- **Calendars** (iCal `.ics` feed URLs): `/admin` (password-gated, see
  `SETTINGS_USERNAME`/`SETTINGS_PASSWORD`).
- **News feeds** (RSS/Atom URLs): `/admin`.
- **Manual sync / status / backups**: `/ops`.

## Backups

The app writes a daily JSON backup to `/data/backups` inside the container
(mounted from the `family_dashboard_data` volume) and also serves one on
demand at `GET /ops/backup.json` (password-gated) — the simplest way to pull a
backup off the device without touching Docker's volume storage directly:

```sh
curl -u family:<SETTINGS_PASSWORD> http://localhost:4000/ops/backup.json -o backup.json
```

To copy the whole volume off-device (e.g. before re-flashing):

```sh
docker run --rm -v family_dashboard_data:/data -v "$PWD":/backup debian \
  tar czf /backup/family_dashboard_data.tar.gz -C /data .
```

## Troubleshooting

- **`docker: readonly database` / writes fail**: means the container isn't
  actually seeing the named volume (or the volume got recreated). Confirm
  with `docker volume inspect family_dashboard_data` and `docker inspect
  family_dashboard --format '{{json .Mounts}}'`.
- **Blank screen / dashboard never updates live**: usually a LiveView socket
  issue. Since `check_origin` is disabled and this deploy serves http-only
  (no `force_ssl` — see `config/prod.exs` and `config/runtime.exs`), this is
  more likely a network/proxy problem than the origin check; verify with
  `docker logs family_dashboard` for socket errors.
- **Redirect loop to https**: shouldn't happen — `force_ssl` was intentionally
  removed from `config/prod.exs` for this deployment. If you see it, check
  you rebuilt the image after that change (force_ssl is compile-time baked,
  so an old image would still have it).
- **Kiosk shows nothing**: `snap logs wpe-webkit-mir-kiosk` and `snap logs
  ubuntu-frame`; confirm `snap connections wpe-webkit-mir-kiosk` shows
  `wayland` connected.
- **Container doesn't survive a reboot**: see "Reboot and confirm autostart"
  above — this is the one part of the architecture that should be verified
  on your specific device/Core revision.
