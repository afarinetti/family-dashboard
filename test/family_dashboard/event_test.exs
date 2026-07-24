defmodule FamilyDashboard.EventTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  defp calendar do
    Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
  end

  describe "create action (upsert on unique_occurrence)" do
    test "creates an event" do
      cal = calendar()
      starts_at = ~U[2026-08-01 12:00:00Z]

      event =
        Dashboard.create_event!(%{
          title: "Dentist",
          starts_at: starts_at,
          uid: "e1",
          calendar_id: cal.id
        })

      assert event.title == "Dentist"
      assert event.starts_at == starts_at
      assert event.calendar_id == cal.id
    end

    test "re-creating the same calendar_id/uid/starts_at updates the row in place, not a duplicate" do
      cal = calendar()
      starts_at = ~U[2026-08-01 12:00:00Z]

      original =
        Dashboard.create_event!(%{
          title: "Dentist",
          starts_at: starts_at,
          ends_at: ~U[2026-08-01 13:00:00Z],
          uid: "e1",
          calendar_id: cal.id
        })

      updated =
        Dashboard.create_event!(%{
          title: "Dentist (moved)",
          starts_at: starts_at,
          ends_at: ~U[2026-08-01 14:00:00Z],
          uid: "e1",
          calendar_id: cal.id
        })

      assert updated.id == original.id
      assert updated.title == "Dentist (moved)"
      assert updated.ends_at == ~U[2026-08-01 14:00:00Z]

      from = DateTime.new!(~D[2026-08-01], ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(~D[2026-08-02], ~T[00:00:00], "Etc/UTC")
      assert [only] = Dashboard.events_in_window!(from, to)
      assert only.id == original.id
    end

    test "the same uid at a different starts_at is a distinct occurrence, not an upsert target" do
      cal = calendar()

      first =
        Dashboard.create_event!(%{
          title: "Standup",
          starts_at: ~U[2026-08-03 09:00:00Z],
          uid: "recurring-1",
          calendar_id: cal.id
        })

      second =
        Dashboard.create_event!(%{
          title: "Standup",
          starts_at: ~U[2026-08-04 09:00:00Z],
          uid: "recurring-1",
          calendar_id: cal.id
        })

      assert first.id != second.id
    end

    test "requires a calendar_id" do
      assert {:error, _} =
               Dashboard.create_event(%{
                 title: "Orphan",
                 starts_at: ~U[2026-08-01 12:00:00Z],
                 uid: "e1"
               })
    end
  end

  describe "in_window read action" do
    test "includes an event whose starts_at falls exactly on the from/to boundary" do
      cal = calendar()
      from = DateTime.new!(~D[2026-08-01], ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(~D[2026-08-02], ~T[00:00:00], "Etc/UTC")

      on_from =
        Dashboard.create_event!(%{
          title: "At from",
          starts_at: from,
          uid: "a",
          calendar_id: cal.id
        })

      on_to =
        Dashboard.create_event!(%{title: "At to", starts_at: to, uid: "b", calendar_id: cal.id})

      ids = from |> Dashboard.events_in_window!(to) |> Enum.map(& &1.id)

      assert on_from.id in ids
      assert on_to.id in ids
    end

    test "excludes events outside the window" do
      cal = calendar()
      from = DateTime.new!(~D[2026-08-01], ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(~D[2026-08-02], ~T[00:00:00], "Etc/UTC")

      Dashboard.create_event!(%{
        title: "Too early",
        starts_at: DateTime.add(from, -1, :second),
        uid: "early",
        calendar_id: cal.id
      })

      Dashboard.create_event!(%{
        title: "Too late",
        starts_at: DateTime.add(to, 1, :second),
        uid: "late",
        calendar_id: cal.id
      })

      assert Dashboard.events_in_window!(from, to) == []
    end

    test "orders results by starts_at ascending and loads the calendar" do
      cal = calendar()
      from = DateTime.new!(~D[2026-08-01], ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(~D[2026-08-05], ~T[00:00:00], "Etc/UTC")

      later =
        Dashboard.create_event!(%{
          title: "Later",
          starts_at: DateTime.add(from, 2, :day),
          uid: "later",
          calendar_id: cal.id
        })

      earlier =
        Dashboard.create_event!(%{
          title: "Earlier",
          starts_at: DateTime.add(from, 1, :day),
          uid: "earlier",
          calendar_id: cal.id
        })

      assert [first, second] = Dashboard.events_in_window!(from, to)
      assert first.id == earlier.id
      assert second.id == later.id
      assert first.calendar.id == cal.id
    end
  end
end
