# Shortcuts for common commands. Run `just` with no arguments to list them.

default:
    just --list

# Install deps, create/migrate/seed the db, build assets.
setup:
    mix setup

# Run the dev server.
server:
    mix phx.server

# Run the dev server with a REPL attached.
console:
    iex -S mix phx.server

# Run the full test suite.
test:
    mix test

# Run a single test file, optionally at a specific line: just test-one test/foo_test.exs 42
test-one file line="":
    mix test {{file}}{{ if line != "" { ":" + line } else { "" } }}

# Re-run only the tests that failed last time.
test-failed:
    mix test --failed

# Compile (warnings as errors), drop unused deps locks, format, and test.
# Run this before considering a change done.
precommit:
    mix precommit

format:
    mix format

# Rebuild CSS/JS (tailwind + esbuild) — run after changing app.css/app.js or adding a new Tailwind class/heroicon.
assets:
    mix assets.build

# Drop and recreate the dev database, then reseed.
db-reset:
    mix ecto.reset

# Re-run the seed script (creates the singleton Setting row if missing).
seed:
    mix run priv/repo/seeds.exs
