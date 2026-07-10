defmodule FamilyDashboard.ICal do
  @moduledoc """
  Facade around the `ical` hex package.

  Fetches/parses an iCalendar (`.ics`) feed and returns concrete, dated
  occurrences within a window — expanding recurrence rules (RRULE), applying
  exceptions (EXDATE), and merging single-occurrence overrides (RECURRENCE-ID).

  The rest of the app depends only on this module and `Occurrence`, never on
  `ICal.*` directly, so the underlying library can be swapped in one place.
  """

  # The `ical` package's top-level module, aliased to avoid confusion with this facade.
  alias ICal, as: ICalLib

  defmodule Occurrence do
    @moduledoc "A single concrete calendar occurrence, resolved to UTC."
    @enforce_keys [:uid, :title, :starts_at]
    defstruct [:uid, :title, :starts_at, :ends_at, :location, all_day?: false]
  end

  @doc """
  Fetches the `.ics` feed at `url` over HTTP and expands it into occurrences
  within the inclusive `[from, to]` window.

  Extra `opts` are forwarded to `Req.get/2` (e.g. a `:plug` stub in tests).
  Returns `{:ok, occurrences}` or `{:error, reason}`.
  """
  @spec fetch_and_expand(String.t(), Date.t(), Date.t(), keyword()) ::
          {:ok, [Occurrence.t()]} | {:error, term()}
  def fetch_and_expand(url, %Date{} = from, %Date{} = to, opts \\ []) do
    case Req.get(url, opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, occurrences_in_window(to_string(body), from, to)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses `ics_text` and returns the occurrences whose start date falls within
  the inclusive `[from, to]` date window, sorted ascending by start.
  """
  @spec occurrences_in_window(String.t(), Date.t(), Date.t()) :: [Occurrence.t()]
  def occurrences_in_window(ics_text, %Date{} = from, %Date{} = to)
      when is_binary(ics_text) do
    ics_text
    |> ICalLib.from_ics()
    |> Map.get(:events, [])
    # A recurring series and its per-occurrence overrides share one UID.
    |> Enum.group_by(& &1.uid)
    |> Enum.flat_map(fn {_uid, group} -> expand_group(group, from, to) end)
    |> Enum.sort_by(& &1.starts_at, DateTime)
  end

  # A UID group is a master series (no RECURRENCE-ID) plus zero or more overrides
  # (each carrying a RECURRENCE-ID pointing at the master occurrence it replaces).
  defp expand_group(events, from, to) do
    {masters, overrides} = Enum.split_with(events, &is_nil(&1.recurrence_id))
    override_map = Map.new(overrides, &{occurrence_key(&1.recurrence_id), &1})

    case masters do
      # Orphan overrides (master not in the feed): treat each as a standalone event.
      [] ->
        overrides
        |> Enum.reject(&cancelled?/1)
        |> Enum.filter(&in_window?(&1.dtstart, from, to))
        |> Enum.map(&to_occurrence/1)

      [master | _] ->
        expand_master(master, override_map, from, to)
    end
  end

  # Non-recurring event: include it if its start lands in the window.
  defp expand_master(%{rrule: nil} = master, _override_map, from, to) do
    if in_window?(master.dtstart, from, to), do: [to_occurrence(master)], else: []
  end

  # Recurring master: stream occurrences (EXDATE/RDATE applied by the library),
  # bound by the window, then splice in overrides by RECURRENCE-ID. `take_while`
  # is a defensive cap in case an unbounded rule ignores end_date.
  defp expand_master(%{rrule: %ICalLib.Recurrence{}} = master, override_map, from, to) do
    master
    |> ICalLib.Recurrence.stream(end_date: to)
    |> Stream.take_while(fn occ -> Date.compare(to_date(occ), to) != :gt end)
    |> Stream.filter(fn occ -> Date.compare(to_date(occ), from) != :lt end)
    |> Enum.flat_map(fn occ ->
      case Map.get(override_map, occurrence_key(occ)) do
        nil -> [occurrence_from(master, occ)]
        override -> if cancelled?(override), do: [], else: [to_occurrence(override)]
      end
    end)
  end

  # Build an occurrence at start `occ`, carrying the master's title/location and
  # preserving its duration. (We avoid the library's apply/2, which crashes when
  # the master has no DTEND — common for all-day events.)
  defp occurrence_from(master, occ) do
    {starts_at, all_day?} = to_datetime(occ)

    %Occurrence{
      uid: master.uid,
      title: master.summary,
      location: master.location,
      starts_at: starts_at,
      ends_at: shifted_end(master, starts_at),
      all_day?: all_day?
    }
  end

  defp shifted_end(%{dtstart: dtstart, dtend: dtend}, starts_at)
       when not is_nil(dtstart) and not is_nil(dtend) do
    {start_dt, _} = to_datetime(dtstart)
    {end_dt, _} = to_datetime(dtend)
    DateTime.add(starts_at, DateTime.diff(end_dt, start_dt), :second)
  end

  defp shifted_end(_master, _starts_at), do: nil

  # Canonical key matching a master occurrence's start to an override's
  # RECURRENCE-ID. Normalized to a UTC instant so zoned (TZID) and UTC (Z)
  # representations of the same moment compare equal.
  defp occurrence_key(value) do
    case to_datetime(value) do
      {nil, _} -> nil
      {dt, _} -> dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
    end
  end

  defp cancelled?(event), do: event.status == :cancelled

  defp to_occurrence(event) do
    {starts_at, all_day?} = to_datetime(event.dtstart)
    {ends_at, _} = to_datetime(event.dtend)

    %Occurrence{
      uid: event.uid,
      title: event.summary,
      location: event.location,
      starts_at: starts_at,
      ends_at: ends_at,
      all_day?: all_day?
    }
  end

  # Normalize the library's three datetime shapes to a UTC DateTime.
  # A bare Date means an all-day (VALUE=DATE) event.
  defp to_datetime(nil), do: {nil, false}
  defp to_datetime(%DateTime{} = dt), do: {dt, false}
  defp to_datetime(%NaiveDateTime{} = ndt), do: {DateTime.from_naive!(ndt, "Etc/UTC"), false}
  defp to_datetime(%Date{} = d), do: {DateTime.new!(d, ~T[00:00:00], "Etc/UTC"), true}

  defp in_window?(nil, _from, _to), do: false

  defp in_window?(value, from, to) do
    date = to_date(value)
    Date.compare(date, from) != :lt and Date.compare(date, to) != :gt
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
end
