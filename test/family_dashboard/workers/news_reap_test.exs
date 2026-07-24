defmodule FamilyDashboard.Workers.NewsReapTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.NewsReap

  test "delegates to NewsReaper.reap/0" do
    assert :ok = perform_job(NewsReap, %{})
  end
end
