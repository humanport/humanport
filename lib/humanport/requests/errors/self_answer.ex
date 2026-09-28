defmodule Humanport.Requests.Errors.SelfAnswer do
  @moduledoc """
  An agent key tried to answer, approve, reject or choose on a request it
  created itself. Wrapped in `Ash.Error.Forbidden` by `Humanport.Requests`,
  so every boundary maps it to its forbidden status (HTTP 403).
  """

  use Splode.Error, fields: [], class: :forbidden

  def message(_error) do
    "An agent key cannot answer a request it created itself."
  end
end
