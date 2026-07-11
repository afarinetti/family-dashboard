defmodule FamilyDashboard.CalendarTest do
  use FamilyDashboard.DataCase

  alias FamilyDashboard.Dashboard

  describe "upsert action (used by FamilyDashboard.Backup to restore calendars)" do
    test "creates a calendar when the id doesn't exist yet" do
      id = Ash.UUID.generate()

      assert {:ok, cal} =
               Dashboard.upsert_calendar(%{id: id, name: "New", ical_url: "https://x/n.ics"})

      assert cal.id == id
      assert cal.name == "New"
    end

    test "updates the existing row in place when the id already exists" do
      cal = Dashboard.create_calendar!(%{name: "Old", ical_url: "https://x/old.ics"})

      assert {:ok, updated} =
               Dashboard.upsert_calendar(%{
                 id: cal.id,
                 name: "New name",
                 ical_url: "https://x/new.ics"
               })

      assert updated.id == cal.id
      assert updated.name == "New name"
      assert Dashboard.list_calendars!() |> length() == 1
    end

    test "does not clobber sync-status fields on an existing row" do
      cal = Dashboard.create_calendar!(%{name: "Family", ical_url: "https://x/cal.ics"})
      synced_at = DateTime.utc_now() |> DateTime.truncate(:second)
      Dashboard.update_calendar!(cal, %{last_synced_at: synced_at})

      assert {:ok, updated} =
               Dashboard.upsert_calendar(%{
                 id: cal.id,
                 name: "Family",
                 ical_url: "https://x/cal.ics"
               })

      assert updated.last_synced_at == synced_at
    end
  end
end
