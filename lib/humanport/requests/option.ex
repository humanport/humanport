defmodule Humanport.Requests.Option do
  @moduledoc """
  The opaque, caller-supplied choose option (CORE-04, locked decision 2 —
  ROADMAP.md "Locked decisions for `choose`"). Each option carries a stable
  `id` the agent branches on, a human-facing `label`, an optional
  `description`, and an advisory `recommended` flag. HumanPort stores and
  returns these fields unchanged and MUST NOT interpret, normalise or map
  them — that is what lets it serve a caller (e.g. GSD) with no
  caller-specific code.

  `description` and the advisory flag are both nullable, with nothing ever
  invented in their place, on purpose: this resource's whole job is to give
  a caller's data back unchanged, and inventing a value is exactly what
  HumanPort must never do. `HumanRequest`'s `risk` attribute already
  establishes exactly this rule for an agent-stated field, in its own
  comment — absent must never render as a stated value. The same applies
  here: an option submitted without a description or without the advisory
  flag must come back with those fields still absent, not filled in with
  anything HumanPort chose on the caller's behalf.

  Embedded (not a standalone table), exactly like `Humanport.Requests.Subject`
  — an option has no identity or lifecycle independent of the request that
  carries it. Ash's default embedded-resource actions (`create: :*`, `read`,
  `update: :*`, `destroy`) apply unchanged; no custom actions block is
  declared here on purpose.
  """

  use Ash.Resource, data_layer: :embedded

  # Ash's `:string` type trims whitespace and folds empty strings to `nil`
  # by default (`Ash.Type.String`'s own `trim?`/`allow_empty?` constraints,
  # both opt-out). Every string attribute below turns both off — HumanPort
  # is a port, not a workflow engine, and trimming a caller's label is
  # exactly the kind of interpretation D-12/locked-decision-2 forbids.
  attributes do
    attribute :id, :string do
      allow_nil? false
      public? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :description, :string do
      public? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :recommended, :boolean, public?: true
  end
end
