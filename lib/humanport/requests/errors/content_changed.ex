defmodule Humanport.Requests.Errors.ContentChanged do
  @moduledoc """
  SEC-08 — a decision named content that is not the request's current,
  unaltered content: either the decider presented a different
  `content_hash`, or the stored content no longer matches the fingerprint
  taken when the request was created. Nothing is recorded; every boundary
  maps this to its conflict status (HTTP 409) so the decider reloads and
  looks again.
  """

  use Splode.Error, fields: [], class: :invalid

  def message(_error) do
    "The request's content is not what was shown. Reload it and review it again before deciding."
  end
end
