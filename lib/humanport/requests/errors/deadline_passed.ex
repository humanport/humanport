defmodule Humanport.Requests.Errors.DeadlinePassed do
  @moduledoc """
  ROUTE-* — a decision arrived after the request's `deadline_at`. Nothing is
  recorded; every boundary maps this to its conflict status (HTTP 409),
  exactly like a decision that lost a race, because the request is — or is
  about to be — expired.
  """

  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "This request's deadline has passed. It can no longer be answered."
end
