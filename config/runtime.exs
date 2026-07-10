import Config
import Dotenvy

# Load optional local `.env` and `.env.<env>` files (silently ignored if absent,
# since `require_files` defaults to false) and export them so the `System.get_env`
# reads below pick them up. Real environment variables are the last source, so
# they always win — production (which ships no `.env`) is unaffected.
#
# Skipped in :test so the suite stays hermetic (a developer's local `.env` must
# not leak a real API key into tests, which would trigger live HTTP calls).
if config_env() != :test do
  source!([".env", ".env.#{config_env()}", System.get_env()])
  |> System.put_env()
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/family_dashboard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :family_dashboard, FamilyDashboardWeb.Endpoint, server: true
end

config :family_dashboard, FamilyDashboardWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# OpenWeatherMap API key (free tier). Weather simply stays empty if unset.
config :family_dashboard, :openweather_api_key, System.get_env("WEATHER_API_KEY")

# Shared-password gate for the settings/admin area. Required in prod; defaulted
# for local dev/test so the app runs out of the box.
settings_password =
  System.get_env("SETTINGS_PASSWORD") ||
    if config_env() == :prod do
      raise """
      environment variable SETTINGS_PASSWORD is missing.
      It guards the settings/admin area (calendars, location, scheduling).
      """
    else
      "family-dashboard"
    end

config :family_dashboard, :settings_auth,
  username: System.get_env("SETTINGS_USERNAME", "family"),
  password: settings_password

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :family_dashboard, FamilyDashboardWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/family_dashboard_web/router\.ex$"E,
        ~r"lib/family_dashboard_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/family_dashboard/family_dashboard.db
      """

  config :family_dashboard, FamilyDashboard.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :family_dashboard, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :family_dashboard, FamilyDashboardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :family_dashboard, FamilyDashboardWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :family_dashboard, FamilyDashboardWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :family_dashboard, FamilyDashboard.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
