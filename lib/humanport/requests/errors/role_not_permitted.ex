defmodule Humanport.Requests.Errors.RoleNotPermitted do
  @moduledoc """
  SEC-02 — an agent key's role does not allow what it tried: a `:responder`
  key creating a request, or a `:requester` key answering, approving,
  rejecting or choosing on one. Wrapped in `Ash.Error.Forbidden` by
  `Humanport.Requests`, so every boundary maps it to its forbidden status
  (HTTP 403, an `isError` tool result over MCP).
  """

  use Splode.Error, fields: [:role, :operation], class: :forbidden

  def message(%{role: role, operation: :submit}) do
    "An agent key with the #{role} role cannot create requests."
  end

  def message(%{role: role, operation: :decide}) do
    "An agent key with the #{role} role cannot answer requests."
  end
end
