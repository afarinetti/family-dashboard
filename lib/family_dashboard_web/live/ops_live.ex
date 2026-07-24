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

  alias FamilyDashboard.Backup
  alias FamilyDashboard.Dashboard
  alias FamilyDashboard.Heartbeat

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "weather")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "events")
        Phoenix.PubSub.subscribe(FamilyDashboard.PubSub, "news")
        reload_status(socket)
      else
        assign(socket, calendars: [], news_feeds: [], setting: nil)
      end

    socket =
      socket
      |> assign(pending_restore: nil, restore_error: nil)
      |> assign_server_backups()
      |> allow_upload(:backup, accept: ~w(.json), max_entries: 1)

    {:ok, socket}
  end

  defp assign_server_backups(socket) do
    case Backup.list_backups() do
      {:ok, backups} ->
        assign(socket, server_backups: backups, server_backups_error: nil)

      {:error, reason} ->
        assign(socket, server_backups: [], server_backups_error: inspect(reason))
    end
  end

  @impl true
  def handle_info(:weather_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:events_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:news_updated, socket), do: {:noreply, reload_status(socket)}
  def handle_info(:reload_status, socket), do: {:noreply, reload_status(socket)}

  defp reload_status(socket) do
    assign(socket,
      calendars: Dashboard.list_calendars!(),
      news_feeds: Dashboard.list_news_feeds!(),
      setting: current_setting()
    )
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
              <h2 class="card-title">News</h2>
              <.button phx-click="refresh_news">Refresh news now</.button>
            </div>
            <ul class="list">
              <li :for={feed <- @news_feeds} class="list-row">
                <div class="list-col-grow">
                  <div class="font-bold">
                    {feed.label}
                    <span class={[
                      "badge badge-sm",
                      feed.enabled && "badge-success",
                      !feed.enabled && "badge-ghost"
                    ]}>
                      {if feed.enabled, do: "enabled", else: "disabled"}
                    </span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    fetched {relative_time(feed.last_fetched_at)}
                  </div>
                  <div :if={feed.last_error} class="text-sm text-error">{feed.last_error}</div>
                </div>
              </li>
            </ul>
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

        <section class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Backup &amp; restore</h2>
            <p class="text-sm text-base-content/70">
              Backs up calendars and settings only — weather and events regenerate on the next sync.
            </p>
            <div class="flex gap-2">
              <.button href={~p"/ops/backup.json"} download>Download backup</.button>
              <.button phx-click="save_backup_to_disk">Save to disk now</.button>
            </div>

            <div class="divider">Restore from an uploaded file</div>

            <form
              id="restore-form"
              phx-submit="confirm_restore"
              phx-change="validate_upload"
              class="flex flex-col gap-2"
            >
              <.live_file_input
                upload={@uploads.backup}
                class="file-input file-input-bordered w-full"
              />
              <p :for={err <- upload_errors(@uploads.backup)} class="text-error text-sm">
                {error_to_string(err)}
              </p>

              <div :if={@pending_restore != :upload}>
                <.button type="button" phx-click="request_restore">
                  Restore from uploaded file…
                </.button>
              </div>

              <div :if={@pending_restore == :upload} class="alert alert-warning">
                <span>This overwrites current calendars and settings. A safety backup is saved first.</span>
                <div class="flex gap-2">
                  <.button type="submit" variant="primary">Yes, overwrite</.button>
                  <.button type="button" phx-click="cancel_restore">Cancel</.button>
                </div>
              </div>
            </form>

            <div class="divider">Restore from a server backup</div>

            <div class="max-h-64 overflow-y-auto rounded-box border border-base-300">
              <p :if={@server_backups_error} class="text-error text-sm p-4">
                Could not list server backups: {@server_backups_error}
              </p>
              <p
                :if={!@server_backups_error && @server_backups == []}
                class="text-sm text-base-content/70 p-4"
              >
                No backups found in {Backup.backup_dir()}.
              </p>
              <ul :if={@server_backups != []} class="list">
                <li :for={backup <- @server_backups} class="list-row">
                  <div class="list-col-grow">
                    <div class="font-mono text-sm">{backup.filename}</div>
                    <div class="text-sm text-base-content/70">
                      saved {relative_time(backup.mtime)}
                    </div>
                  </div>

                  <.button
                    :if={@pending_restore != {:server, backup.filename}}
                    phx-click="request_restore_from_server"
                    phx-value-filename={backup.filename}
                  >
                    Restore this backup
                  </.button>

                  <div
                    :if={@pending_restore == {:server, backup.filename}}
                    class="alert alert-warning"
                  >
                    <span>
                      Overwrite current calendars and settings with this backup? A safety backup is saved first.
                    </span>
                    <div class="flex gap-2">
                      <.button
                        phx-click="confirm_restore_from_server"
                        phx-value-filename={backup.filename}
                        variant="primary"
                      >
                        Yes, overwrite
                      </.button>
                      <.button phx-click="cancel_restore">Cancel</.button>
                    </div>
                  </div>
                </li>
              </ul>
            </div>

            <p :if={@restore_error} class="text-error text-sm mt-2">{@restore_error}</p>
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

  def handle_event("refresh_news", _params, socket) do
    Heartbeat.enqueue_news(true)
    schedule_status_reload()
    {:noreply, put_flash(socket, :info, "News refresh queued.")}
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

  def handle_event("save_backup_to_disk", _params, socket) do
    case Backup.export_json() |> Backup.write_to_disk() do
      {:ok, path} ->
        socket =
          socket
          |> put_flash(:info, "Backup saved to #{path}.")
          |> assign_server_backups()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Backup failed: #{inspect(reason)}")}
    end
  end

  def handle_event("request_restore", _params, socket) do
    {:noreply, assign(socket, pending_restore: :upload, restore_error: nil)}
  end

  def handle_event("request_restore_from_server", %{"filename" => filename}, socket) do
    {:noreply, assign(socket, pending_restore: {:server, filename}, restore_error: nil)}
  end

  def handle_event("cancel_restore", _params, socket) do
    {:noreply, assign(socket, pending_restore: nil, restore_error: nil)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_restore", _params, socket) do
    case socket.assigns.pending_restore do
      :upload -> do_confirm_restore_from_upload(socket)
      _ -> {:noreply, assign(socket, restore_error: "Restore was not confirmed.")}
    end
  end

  def handle_event("confirm_restore_from_server", %{"filename" => filename}, socket) do
    case socket.assigns.pending_restore do
      {:server, ^filename} -> do_confirm_restore_from_server(socket, filename)
      _ -> {:noreply, assign(socket, restore_error: "Restore was not confirmed.")}
    end
  end

  defp do_confirm_restore_from_upload(socket) do
    entries =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case entries do
      [json] -> apply_restore(socket, json)
      [] -> {:noreply, assign(socket, restore_error: "Choose a backup file first.")}
    end
  end

  defp do_confirm_restore_from_server(socket, filename) do
    case Backup.read_backup(filename) do
      {:ok, json} ->
        apply_restore(socket, json)

      {:error, reason} ->
        {:noreply, assign(socket, restore_error: "Could not read backup: #{inspect(reason)}")}
    end
  end

  defp apply_restore(socket, json) do
    case Backup.import_json(json) do
      {:ok, %{calendars_restored: n}} ->
        socket =
          socket
          |> put_flash(:info, "Restored #{n} calendar(s) and the settings.")
          |> assign(pending_restore: nil, restore_error: nil)
          |> assign_server_backups()
          |> reload_status()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, restore_error: inspect(reason))}
    end
  end

  # Success re-loads the panel via the PubSub handlers above, but a fetch
  # *failure* records status without broadcasting — this delayed reload
  # catches that case too, so an errored manual trigger still shows up.
  defp schedule_status_reload, do: Process.send_after(self(), :reload_status, 2_000)

  defp max_attempts(nil), do: 3
  defp max_attempts(setting), do: setting.sync_max_attempts || 3

  defp error_to_string(:too_large), do: "File too large."
  defp error_to_string(:not_accepted), do: "Must be a .json file."
  defp error_to_string(:too_many_files), do: "Only one file at a time."
end
