defmodule FamilyDashboard.Workers.NewsRefreshTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.NewsRefresh

  # With no enabled feeds, News.refresh_all/0 never makes an HTTP call, so this
  # is safe to exercise directly rather than needing a Req.Test stub — the
  # worker itself calls News.refresh_all/0 with no opts, so a feed-fetching
  # path isn't reachable from a worker-level test anyway (see NewsTest for
  # feed-fetch coverage against News.refresh_all/1's opts).
  test "delegates to News.refresh_all/0" do
    assert :ok = perform_job(NewsRefresh, %{})
  end
end
