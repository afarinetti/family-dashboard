defmodule FamilyDashboard.Validations.ValidSeverity do
  @moduledoc """
  Rejects an `alerts_min_severity` that isn't one of the four normalized
  severity tokens `FamilyDashboard.Weather.Provider.fetch_alerts/4` can
  produce (see its moduledoc). Without this, a typo written via `/admin`
  would make `DashboardLive`'s `severity_rank/1` comparison silently rank the
  threshold at 0 (matches nothing recognized) rather than raising — so the
  symptom would be "the alerts card never appears," discovered far from its
  cause. This validation catches the typo at write time instead.
  """
  use Ash.Resource.Validation

  @valid_severities ~w(extreme severe moderate minor)

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :alerts_min_severity) do
      nil ->
        :ok

      severity when severity in @valid_severities ->
        :ok

      _ ->
        {:error,
         field: :alerts_min_severity,
         message: "must be one of: #{Enum.join(@valid_severities, ", ")}"}
    end
  end
end
