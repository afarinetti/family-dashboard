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
  alias FamilyDashboard.Heartbeat

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
            <div class="flex gap-2 mt-2">
              <.button phx-click="refresh_weather">Refresh weather now</.button>
              <.button phx-click="refresh_daily">Refresh 7-day now</.button>
            </div>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title">Calendars</h2>
              <.button phx-click="sync_all_calendars">Sync all active</.button>
            </div>
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
                <.button phx-click="sync_calendar" phx-value-id={cal.id}>Sync now</.button>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("refresh_weather", _params, socket) do
    Heartbeat.enqueue_weather(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "Weather refresh queued.")}
  end

  def handle_event("refresh_daily", _params, socket) do
    Heartbeat.enqueue_daily(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "7-day forecast refresh queued.")}
  end

  def handle_event("sync_calendar", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.calendars, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown calendar.")}

      calendar ->
        Heartbeat.enqueue_calendar(calendar.id, max_attempts(socket.assigns.setting), true)
        schedule_status_reload()
        {:noreply, put_flash(socket, :info, "Sync queued for #{calendar.name}.")}
    end
  end

  def handle_event("sync_all_calendars", _params, socket) do
    active = Enum.filter(socket.assigns.calendars, & &1.active)
    max_attempts = max_attempts(socket.assigns.setting)

    Enum.each(active, &Heartbeat.enqueue_calendar(&1.id, max_attempts, true))
    schedule_status_reload()

    {:noreply, put_flash(socket, :info, "Queued #{length(active)} calendar(s).")}
  end

  # Success re-loads the panel via the PubSub handlers above, but a fetch
  # *failure* records status without broadcasting — this delayed reload
  # catches that case too, so an errored manual trigger still shows up.
  defp schedule_status_reload, do: Process.send_after(self(), :reload_status, 2_000)

  defp max_attempts(nil), do: 3
  defp max_attempts(setting), do: setting.sync_max_attempts || 3
end
