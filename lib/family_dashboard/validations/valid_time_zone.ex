defmodule FamilyDashboard.Validations.ValidTimeZone do
  @moduledoc """
  Rejects a `time_zone` that isn't a resolvable IANA identifier.

  Without this, a typo in the settings admin would make the public dashboard's
  `DateTime.now!/1` raise on mount — crash-looping an always-on wall display.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :time_zone) do
      nil ->
        :ok

      time_zone ->
        case DateTime.now(time_zone) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, field: :time_zone, message: "is not a valid IANA time zone"}
        end
    end
  end
end
