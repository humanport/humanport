defmodule Humanport.Requests.Validations.ChooseRequiresOptions do
  @moduledoc """
  The converse of `Humanport.Requests.Changes.DeriveChooseType` — a request
  of the `choose` type with no options, or with an empty option list, is
  refused with a field-level message: a choice nobody can make is a request
  that can never reach a terminal state, and nothing in this system may
  create one of those.

  In practice `DeriveChooseType` already forces `type: :choose` whenever
  options are present, so the only way `type == :choose` reaches this
  validation with an empty option list is a caller explicitly sending
  `type: "choose"` and no options (or an empty list) — exactly the case this
  guards against.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)
    options = Ash.Changeset.get_attribute(changeset, :options)

    if type == :choose and (is_nil(options) or options == []) do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :options,
         message: "a choose request must offer at least one option"
       )}
    else
      :ok
    end
  end
end
