defmodule FamilyDashboardWeb.OpsLive do
  @moduledoc """
  The ops hub: manual sync triggers, a sync-status health panel, and
  calendars/settings backup & restore. Password-gated (same `:settings_area`
  pipeline as `/admin` and `/oban`) — this is an operator page, not the wall
  display, so normal interactive sizing applies rather than the dashboard's
  wall-scale type.

  Unlike `DashboardLive`, the initial data load only runs on the *connected*
  mount, not the disconnected dead render — the dead render just shows an
  empty shell, avoiding a duplicate DB read on every page load.
  """
  use FamilyDashboardWeb, :live_view

  alias FamilyDashboard.Dashboard

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
        reload_status(socket)
      else
        assign(socket, calendars: [], setting: nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:weather_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:events_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:reload_status, socket), do: {:noreply, reload_status(socket)}

  defp reload_status(socket) do
    assign(socket, calendars: Dashboard.list_calendars!(), setting: current_setting())
  end

  defp current_setting do
    case Dashboard.current_setting() do
      {:ok, setting} -> setting
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-3xl mx-auto p-6 flex flex-col gap-6">
        <.header>Ops</.header>

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Weather</h2>
            <p :if={@setting} class="text-sm text-base-content/70">
              Current+hourly last attempted {relative_time(@setting.weather_last_attempted_at)}
            </p>
            <p :if={@setting && @setting.weather_last_error} class="text-error text-sm">
              {@setting.weather_last_error}
            </p>
            <p :if={@setting} class="text-sm text-base-content/70">
              7-day last attempted {relative_time(@setting.daily_last_attempted_at)}
            </p>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Calendars</h2>
            <ul class="list">
              <li :for={cal <- @calendars} class="list-row">
                <div class="list-col-grow">
                  <div class="font-bold">
                    {cal.name}
                    <span class={[
                      "badge badge-sm",
                      cal.active && "badge-success",
                      !cal.active && "badge-ghost"
                    ]}>
                      {if cal.active, do: "active", else: "inactive"}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    synced {relative_time(cal.last_synced_at)}
                  </div>
                  <div :if={cal.last_error} class="text-sm text-error">{cal.last_error}</div>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
