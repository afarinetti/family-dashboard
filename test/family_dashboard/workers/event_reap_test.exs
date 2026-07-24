defmodule FamilyDashboard.Workers.EventReapTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.EventReap

  test "delegates to EventReaper.reap/0" do
    assert :ok = perform_job(EventReap, %{})
  end
end
