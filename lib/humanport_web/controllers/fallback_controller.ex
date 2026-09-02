defmodule HumanportWeb.FallbackController do
  @moduledoc """
  Pattern 7 — maps the *contained* Ash error, not merely its class, to an
  HTTP status and the plain-v1 `{"error": {"code", "message", "details"}}`
  envelope. Both "you sent nonsense" and "someone beat you to it" arrive as
  `Ash.Error.Invalid`, and the split between them is the whole point: 409
  tells an agent to stop retrying and read the answer; 422 tells it its
  request was malformed. Collapsing the two makes the agent retry a request
  that is already decided, forever.

  Wired via `action_fallback` on `HumanportWeb.RequestController` — every
  controller action there returns either a rendered `conn` or a bare
  `{:error, term()}`, and Phoenix dispatches the latter here.
  """

  use HumanportWeb, :controller

  @terminal_states ~w(answered approved rejected)

  def call(conn, {:error, error}) do
    {status, code, message, details} = map_error(error)

    conn
    |> put_status(status)
    |> put_view(json: HumanportWeb.RequestJSON)
    |> render(:error, code: code, message: message, details: details)
  end

  # Ash not-found.
  defp map_error(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        {:not_found, "not_found", "Request not found.", %{}}

      # Ash stale-record — the atomic `filter(expr(is_nil(completed_at)))`
      # guard (Pattern 4(b)) lost this row to a concurrent responder.
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        {:conflict, "conflict", "This request was already answered.", %{}}

      transition_error =
          Enum.find(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) ->
        map_no_matching_transition(transition_error)

      not_implemented_error = Enum.find(errors, &not_implemented_type?/1) ->
        {:unprocessable_entity, "not_implemented", not_implemented_message(not_implemented_error),
         %{}}

      true ->
        {:unprocessable_entity, "invalid", Ash.Error.error_descriptions(errors),
         field_details(errors)}
    end
  end

  # No authorization in Phase 1 (D-09/D-11) — nothing in this application
  # currently raises this, but the mapping is here so a future policy
  # addition fails closed with a status rather than falling through to 500.
  defp map_error(%Ash.Error.Forbidden{errors: errors}) do
    {:forbidden, "invalid", Ash.Error.error_descriptions(errors), %{}}
  end

  # Framework or unknown-class errors — never leak a stack trace, SQL, or an
  # internal module name onto the wire (T-01-23).
  defp map_error(_error) do
    {:internal_server_error, "internal", "Your answer could not be saved.", %{}}
  end

  # AshStateMachine.Errors.NoMatchingTransition arrives for two different
  # reasons that must not collapse into one status: the old state is already
  # terminal (someone else answered first — a conflict, 409) or it is not (a
  # genuinely malformed transition attempt — 422). Phase 1's transition
  # table only ever declares `from: :pending`, so in practice `old_state` is
  # always terminal when this error fires at all — but the split is written
  # explicitly rather than assumed, because a future phase's transition
  # table will make the `422` branch reachable.
  defp map_no_matching_transition(
         %AshStateMachine.Errors.NoMatchingTransition{old_state: old_state} = error
       ) do
    if to_string(old_state) in @terminal_states do
      {:conflict, "conflict", "This request was already answered.", %{}}
    else
      {:unprocessable_entity, "invalid", Exception.message(error), %{}}
    end
  end

  defp not_implemented_type?(%Ash.Error.Changes.InvalidAttribute{field: :type, message: message}) do
    is_binary(message) and String.contains?(message, "not implemented")
  end

  defp not_implemented_type?(_), do: false

  defp not_implemented_message(%Ash.Error.Changes.InvalidAttribute{value: value}) do
    "HumanPort recorded a #{value} request, but this version answers only ask and approve."
  end

  defp field_details(errors) do
    errors
    |> Enum.filter(&Map.has_key?(&1, :field))
    |> Enum.map(fn error -> %{field: error.field, message: Exception.message(error)} end)
  end
end
