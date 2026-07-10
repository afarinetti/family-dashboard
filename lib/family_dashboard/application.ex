defmodule FamilyDashboard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FamilyDashboardWeb.Telemetry,
      FamilyDashboard.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:family_dashboard, :ecto_repos), skip: skip_migrations?()},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:family_dashboard, :ash_domains),
         Application.fetch_env!(:family_dashboard, Oban)
       )},
      # Start a worker by calling: FamilyDashboard.Worker.start_link(arg)
      # {FamilyDashboard.Worker, arg},
      # Start to serve requests, typically the last entry
      {DNSCluster, query: Application.get_env(:family_dashboard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FamilyDashboard.PubSub},
      FamilyDashboardWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FamilyDashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FamilyDashboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
