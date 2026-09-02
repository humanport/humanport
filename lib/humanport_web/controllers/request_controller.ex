defmodule HumanportWeb.RequestController do
  @moduledoc """
  PROTO-01 — the agent-facing HTTP surface, fixed by the Task 1 checkpoint
  decision (`plain-v1`): plain Phoenix JSON controllers under `/api/v1`, no
  envelope imposed on the body.

  `POST /api/v1/requests` → 201 with the full request object.
  `GET /api/v1/requests/:id` → 200 with `status`, `state` and `result`
  (`result` is null while pending; the `?wait=` long-poll parameter is NOT
  implemented here — plan 01-04 adds it).
  `POST /api/v1/requests/:id/respond` → 200, or 409 conflict / 422 invalid /
  404 not found.

  Errors render as `{"error": {"code", "message", "details"}}` with the code
  set `not_found | conflict | invalid | not_implemented | internal`.

  Every action calls `Humanport.Requests` — never builds a changeset and
  never decides a transition itself (§5.2, §54.12).
  """

  use HumanportWeb, :controller

  alias Humanport.Requests

  def create(conn, params) do
    case Requests.submit(params, conn.assigns.actor) do
      {:ok, request} ->
        conn
        |> put_status(:created)
        |> render(:show, request: request)

      {:error, error} ->
        render_error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    case Requests.get_request(id) do
      {:ok, request} -> render(conn, :show, request: request)
      {:error, error} -> render_error(conn, error)
    end
  end

  def respond(conn, %{"id" => id} = params) do
    answer = Map.get(params, "answer")

    with {:ok, request} <- Requests.get_request(id),
         {:ok, answered} <- Requests.answer(request, answer, conn.assigns.actor) do
      render(conn, :show, request: answered)
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  defp render_error(conn, error) do
    {status, code, message} = map_error(error)

    conn
    |> put_status(status)
    |> render(:error, code: code, message: message, details: %{})
  end

  # Pattern 7 — inspect the *contained* error, not only the class: both "you
  # sent nonsense" and "someone beat you to it" arrive as Ash.Error.Invalid.
  defp map_error(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        {:not_found, "not_found", "Request not found."}

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        {:conflict, "conflict", "This request was already answered."}

      Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) ->
        {:conflict, "conflict", "This request was already answered."}

      Enum.any?(errors, &not_implemented_type?/1) ->
        {:unprocessable_entity, "not_implemented",
         "This request type cannot be created in this version."}

      true ->
        {:unprocessable_entity, "invalid", Ash.Error.error_descriptions(errors)}
    end
  end

  defp map_error(%Ash.Error.Forbidden{errors: errors}) do
    {:forbidden, "invalid", Ash.Error.error_descriptions(errors)}
  end

  defp map_error(_error) do
    {:internal_server_error, "internal", "Your answer could not be saved."}
  end

  defp not_implemented_type?(%Ash.Error.Changes.InvalidAttribute{field: :type, message: message}) do
    is_binary(message) and String.contains?(message, "not implemented")
  end

  defp not_implemented_type?(_), do: false
end
