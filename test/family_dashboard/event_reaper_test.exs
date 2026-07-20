defmodule FamilyDashboard.EventReaperTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.{Dashboard, EventReaper}

  defp create_calendar do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://example.com/cal.ics"})
  end

  defp create_event(calendar, uid, starts_at) do
    Dashboard.create_event!(%{
      calendar_id: calendar.id,
      uid: uid,
      title: "Event #{uid}",
      starts_at: starts_at
    })
  end

  defp event_ids do
    FamilyDashboard.Event |> Ash.read!() |> Enum.map(& &1.id)
  end

  test "deletes events whose start is older than the retention window" do
    cal = create_calendar()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old = create_event(cal, "old", DateTime.add(now, -72, :hour))
    recent = create_event(cal, "recent", DateTime.add(now, 2, :hour))

    assert :ok = EventReaper.reap()

    assert event_ids() == [recent.id]
    refute old.id in event_ids()
  end

  test "keeps a today/future event" do
    cal = create_calendar()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    today = create_event(cal, "today", now)
    future = create_event(cal, "future", DateTime.add(now, 5, :day))

    assert :ok = EventReaper.reap()

    assert Enum.sort(event_ids()) == Enum.sort([today.id, future.id])
  end

  # Guards against regressing near-midnight events the agenda's 1-day
  # over-fetch (dashboard_live.ex) can still display.
  test "keeps an event within the retention margin (~1 day old)" do
    cal = create_calendar()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    within_margin = create_event(cal, "within", DateTime.add(now, -24, :hour))

    assert :ok = EventReaper.reap()

    assert event_ids() == [within_margin.id]
  end

  test "does nothing when there are no events" do
    assert :ok = EventReaper.reap()
    assert event_ids() == []
  end
end
