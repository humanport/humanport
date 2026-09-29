defmodule Humanport.Requests.Validations.DeadlineInFuture do
  @moduledoc """
  ROUTE-* — a request's `deadline_at`, when given, must be in the future: a
  request cannot be born already expired. Used on `:submit` only, a create,
  so it has no bearing on the atomic decision actions.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :deadline_at) do
      nil ->
        :ok

      deadline_at ->
        if DateTime.compare(deadline_at, DateTime.utc_now()) == :gt,
          do: :ok,
          else: {:error, field: :deadline_at, message: "must be in the future"}
    end
  end
end
