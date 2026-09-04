defmodule Humanport.Requests.Changes.DeriveChooseType do
  @moduledoc """
  D-12 / locked decision 1 — the presence of options makes a request a
  choice; a caller must not have to supply the `choose` type separately and
  keep it in step with the option list. When a non-empty `options` list is
  present on the changeset, the `type` attribute is forced to `:choose`
  regardless of whatever type the caller sent (or omitted).

  Declared BEFORE `validate one_of(:type, ...)` on the `:submit` action —
  Ash runs an action's changes and validations in declaration order, and
  this change must see-and-set the type before that validation runs, or a
  caller who sends `type: "ask"` together with options would be rejected
  instead of silently upgraded to `choose`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if choose_options?(changeset) do
      Ash.Changeset.force_change_attribute(changeset, :type, :choose)
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if choose_options?(changeset) do
      {:atomic, %{type: :choose}}
    else
      {:atomic, %{}}
    end
  end

  defp choose_options?(changeset) do
    case Ash.Changeset.get_attribute(changeset, :options) do
      options when is_list(options) -> options != []
      _ -> false
    end
  end
end
