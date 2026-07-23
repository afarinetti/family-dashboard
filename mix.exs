defmodule FamilyDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :family_dashboard,
      version: "0.1.0",
      elixir: "~> 1.17",
      licenses: ["Apache-2.0"],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      releases: releases()
    ]
  end

  # Bundles ERTS so the runner image doesn't need a matching Erlang install —
  # see the Containerfile's builder stage (`mix release`). No `rel/` overlays:
  # migrations self-run at boot (see FamilyDashboard.Application) and this
  # single-node kiosk deploy has no clustering to configure.
  defp releases do
    [
      family_dashboard: [
        include_executables_for: [:unix],
        steps: [:assemble]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {FamilyDashboard.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:oban, "~> 2.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_ai, "~> 0.7"},
      {:live_debugger, "~> 1.0", only: [:dev]},
      {:ash_state_machine, "~> 0.2"},
      {:oban_web, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_admin, "~> 1.0"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:ical, "~> 3.0"},
      {:fiet, "~> 0.3.0"},
      {:tz, "~> 0.28"},
      {:dotenvy, "~> 1.1"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind family_dashboard", "esbuild family_dashboard"],
      "assets.deploy": [
        "tailwind family_dashboard --minify",
        "esbuild family_dashboard --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      "ash.setup": ["ash.setup", "run priv/repo/seeds.exs"]
    ]
  end
end
