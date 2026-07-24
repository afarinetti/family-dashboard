# Multi-stage build for family_dashboard.
#
# Engine-agnostic OCI image — builds and runs identically under `docker build`/
# `docker run` or `podman build`/`podman run`. On the deployment target (an
# Ubuntu Core kiosk device) it runs under the Docker snap; see deploy/README.md
# for why Podman isn't viable there.
#
# mix.exs declares `elixir: "~> 1.17"`, but that's not actually the floor:
# config/runtime.exs uses the `E` (:export) Regex sigil modifier, which
# doesn't exist before Elixir 1.19/OTP 28 — confirmed the hard way, an
# Elixir 1.18.4/OTP 27.3.4 build crashed at boot with
# `Regex.CompileError: invalid_option at position E`. Elixir 1.19.5/OTP 28
# builds and boots correctly (verified locally) and matches local dev. Tag
# confirmed to exist at https://hub.docker.com/r/hexpm/elixir/tags.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.3
ARG DEBIAN_VERSION=bookworm-20260713-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# ---- Builder ----------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# build-essential + git: exqlite compiles a NIF (needs a C toolchain + make),
# and the GitHub deps (heroicons, daisyui — compile: false, but still fetched
# via git) need git at dependency-fetch time. No Node.js: assets are
# mix-managed esbuild/tailwind standalone binaries (see `assets.deploy` alias).
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Dependencies (cached separately from source so `mix deps.get` only reruns
# when mix.exs/mix.lock change).
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config (config.exs + prod.exs) must be present before
# `deps.compile`/`compile` — this is also where `force_ssl` is baked in (see
# config/prod.exs — it cannot be set later via runtime.exs).
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# FamilyDashboardWeb.WeatherIcons embeds assets/vendor/meteocons/**/*.svg
# into the compiled BEAM at *compile* time (`@external_resource` +
# `File.read!/1`), so those files must exist before `mix compile` runs —
# copied separately (and first) from the rest of assets/ so routine CSS/JS
# edits don't bust this layer's cache; the vendored icons rarely change.
COPY assets/vendor assets/vendor

# Application source must compile *before* the full asset build: Phoenix
# 1.8's colocated hooks/CSS feature generates
# `phoenix-colocated/family_dashboard/colocated.css` as a side effect of
# compiling lib/ (via the `:phoenix_live_view` compiler in mix.exs), and
# tailwind's build fails without it. (Discovered by an actual build failure —
# `mix assets.deploy` before `mix compile` errors with "Can't resolve
# 'phoenix-colocated/family_dashboard/colocated.css'".)
COPY priv priv
COPY lib lib
RUN mix compile

# Assets — tailwind + esbuild binaries are downloaded by `assets.setup`
# (invoked transitively) and run against priv/assets + assets/; output is
# digested into priv/static/cache_manifest.json (referenced by
# config/prod.exs).
COPY assets assets
RUN mix assets.deploy

# runtime.exs is copied last and is NOT evaluated at build time — it is
# bundled into the release and read at boot.
COPY config/runtime.exs config/
RUN mix release

# ---- Runner -------------------------------------------------------------
FROM ${RUNNER_IMAGE}

# libstdc++6/openssl: required by the BEAM/crypto NIFs. libncurses6: backs the
# readline used by `bin/family_dashboard remote` for a live console. No
# `sqlite3` package — exqlite statically compiles SQLite into its own NIF, so
# the system library isn't used. `curl`: container healthcheck probes the
# public `/` LiveView (the app has no dedicated /health route).
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates locales curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Fixed uid/gid so a bind-mounted or snap-managed volume's ownership is
# predictable across image rebuilds (see deploy/README.md for the Ubuntu Core
# volume story).
RUN groupadd -g 1000 app && useradd -u 1000 -g app -m -d /app app

# /data is the persistent volume mount point for the SQLite DB + WAL/SHM
# sidecars (Oban's job queue lives in the same file — see
# lib/family_dashboard/repo.ex) and the daily JSON backups
# (lib/family_dashboard/backup.ex).
RUN mkdir -p /data/backups && chown -R app:app /data /app

COPY --from=builder --chown=app:app /app/_build/prod/rel/family_dashboard ./

ENV HOME=/app
ENV MIX_ENV=prod
ENV PHX_SERVER=true
ENV DATABASE_PATH=/data/family_dashboard.db
ENV BACKUP_DIR=/data/backups

USER app

EXPOSE 4000

VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:4000/ || exit 1

CMD ["bin/family_dashboard", "start"]
