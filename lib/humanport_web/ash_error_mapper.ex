defmodule HumanportWeb.AshErrorMapper do
  @moduledoc """
  02.1-02-PLAN.md Task 2 — the single Ash-error-to-boundary-error taxonomy,
  extracted from `HumanportWeb.FallbackController`'s original `map_error/1`
  so `HumanportWeb.McpController` can reuse the exact same not-found /
  already-decided (conflict) / malformed (invalid) / not-implemented split
  without a second copy of the `match?` clauses drifting out of sync
  (`02.1-PATTERNS.md` "JSON-RPC error mapping for the MCP transport").

  `classify/1` returns the classification and a human-readable message;
  `details/1` returns the field-level detail array `FallbackController`
  renders into the plain-v1 `details` field (`[]` for every classification
  except the generic `:invalid` case — the MCP surface has no use for this,
  since a tool-originated error is reported as prose in the result, not a
  field-detail list).

  The split is the whole point and must survive whichever envelope the
  caller renders it into: an already-decided request tells an agent to
  stop retrying and read the answer, while a malformed request tells it
  the call itself was wrong. Collapsing the two makes an agent retry a
  request that is already decided, forever (`fallback_controller.ex`'s own
  original moduledoc, reproduced here because the same is now true of
  every caller).
  """

  @terminal_states ~w(answered approved rejected)

  @type classification ::
          :not_found | :conflict | :invalid | :not_implemented | :forbidden | :internal

  @doc "Classifies `error` into `{classification, message}`, reusable by any boundary."
  @spec classify(term()) :: {classification(), String.t()}
  def classify(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        {:not_found, "Request not found."}

      # Ash stale-record — the atomic `filter(expr(is_nil(completed_at)))`
      # guard lost this row to a concurrent responder.
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        {:conflict, "This request was already answered."}

      transition_error =
          Enum.find(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) ->
        classify_no_matching_transition(transition_error)

      not_implemented_error = Enum.find(errors, &not_implemented_type?/1) ->
        {:not_implemented, not_implemented_message(not_implemented_error)}

      true ->
        {:invalid, Ash.Error.error_descriptions(errors)}
    end
  end

  # No authorization in Phase 1 (D-09/D-11) — nothing currently raises
  # this; the mapping exists so a future policy addition fails closed
  # with a status rather than falling through to :internal.
  def classify(%Ash.Error.Forbidden{errors: errors}) do
    {:forbidden, Ash.Error.error_descriptions(errors)}
  end

  # Framework or unknown-class errors — never leak a stack trace, SQL, or
  # an internal module name onto the wire (T-01-23).
  def classify(_error) do
    {:internal, "Your answer could not be saved."}
  end

  @doc """
  Field-level detail for the generic `:invalid` classification — `[]` for
  every other classification.
  """
  @spec details(term()) :: [map()]
  def details(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.filter(&Map.has_key?(&1, :field))
    |> Enum.map(fn error -> %{field: error.field, message: Exception.message(error)} end)
  end

  def details(_error), do: []

  # AshStateMachine.Errors.NoMatchingTransition arrives for two different
  # reasons that must not collapse into one classification: the old state
  # is already terminal (someone else answered first — a conflict) or it
  # is not (a genuinely malformed transition attempt — invalid). Phase 1's
  # transition table only ever declares `from: :pending`, so in practice
  # `old_state` is always terminal when this error fires at all — but the
  # split is written explicitly rather than assumed, because a future
  # phase's transition table will make the `:invalid` branch reachable.
  defp classify_no_matching_transition(
         %AshStateMachine.Errors.NoMatchingTransition{old_state: old_state} = error
       ) do
    if to_string(old_state) in @terminal_states do
      {:conflict, "This request was already answered."}
    else
      {:invalid, Exception.message(error)}
    end
  end

  defp not_implemented_type?(%Ash.Error.Changes.InvalidAttribute{field: :type, message: message}) do
    is_binary(message) and String.contains?(message, "not implemented")
  end

  defp not_implemented_type?(_), do: false

  defp not_implemented_message(%Ash.Error.Changes.InvalidAttribute{value: value}) do
    "HumanPort recorded a #{value} request, but this version answers only ask and approve."
  end
end
