defmodule FamilyDashboard.Workers.BackupTest do
  use FamilyDashboard.DataCase
  use Oban.Testing, repo: FamilyDashboard.Repo

  alias FamilyDashboard.Workers.Backup, as: BackupWorker

  @tmp_dir Path.join(System.tmp_dir!(), "family_dashboard_backup_worker_test")

  setup do
    File.rm_rf!(@tmp_dir)
    original = Application.get_env(:family_dashboard, :backup_dir)
    Application.put_env(:family_dashboard, :backup_dir, @tmp_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.put_env(:family_dashboard, :backup_dir, original)
    end)

    :ok
  end

  test "writes a backup file to the configured directory" do
    assert :ok = perform_job(BackupWorker, %{})
    assert File.ls!(@tmp_dir) != []
  end
end
