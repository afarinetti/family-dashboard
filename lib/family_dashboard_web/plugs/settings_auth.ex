defmodule FamilyDashboardWeb.Plugs.SettingsAuth do
  @moduledoc """
  Guards the settings/admin area with a shared password (HTTP Basic Auth).

  Credentials are read at request time from `:family_dashboard, :settings_auth`
  (set in `config/runtime.exs` from env vars), so the public dashboard stays
  open while `/admin` and the Oban dashboard require the family password.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = Application.get_env(:family_dashboard, :settings_auth, [])

    Plug.BasicAuth.basic_auth(conn,
      username: config[:username] || "family",
      password: config[:password] || "family-dashboard"
    )
  end
end
