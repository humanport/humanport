defmodule Humanport.Requests.Subject do
  @moduledoc """
  D-08 — the narrow subject model: type + id + label, e.g.
  `%{type: "deployment", id: "...", label: "Release 1.4 to prod"}`.

  Enough structure for Phase 5 to route and filter on subject type without
  building the full §7 subject model now. Embedded (not a standalone table) —
  a subject has no identity or lifecycle independent of the request it
  describes. Ash's default embedded-resource actions (`create: :*`, `read`,
  `update: :*`, `destroy`) apply unchanged; no `actions do` block is declared
  here on purpose.
  """

  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :type, :string, public?: true
    attribute :id, :string, public?: true
    attribute :label, :string, public?: true
  end
end
