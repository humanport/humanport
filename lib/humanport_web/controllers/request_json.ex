defmodule HumanportWeb.RequestJSON do
  @moduledoc """
  The D-03/D-22 wire shape, fixed by the Task 1 checkpoint decision: no
  envelope, both the coarse `status` and the canonical `state` at different
  resolutions, `result` null while pending.
  """

  alias Humanport.Requests.HumanRequest
  alias Humanport.Requests.Option
  alias Humanport.Requests.Subject

  def show(%{request: request}) do
    data(request)
  end

  def error(%{code: code, message: message, details: details}) do
    %{error: %{code: code, message: message, details: details}}
  end

  defp data(%HumanRequest{} = request) do
    %{
      id: request.id,
      type: request.type,
      title: request.title,
      description: request.description,
      context: request.context,
      subject: subject(request.subject),
      source: request.source,
      external_correlation: request.external_correlation,
      risk: request.risk,
      reversible: request.reversible,
      requester_label: request.requester_label,
      requester_verified: request.requester_verified,
      # CORE-04 — the opaque option list and its two request-level limits.
      # `options(nil)` renders `null`, never `[]`: a caller who sent no
      # options and a caller who sent an empty one are saying different
      # things and the wire keeps them apart.
      options: options(request.options),
      allow_free_text: request.allow_free_text,
      max_selections: request.max_selections,
      # D-22 — both, at different resolutions. `status` is coarse
      # (pending|completed, D-03); `state` is the canonical §11 machine state.
      state: request.state,
      status: status(request),
      result: result(request),
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end

  defp status(%HumanRequest{completed_at: nil}), do: :pending
  defp status(%HumanRequest{}), do: :completed

  defp result(%HumanRequest{completed_at: nil}), do: nil

  defp result(%HumanRequest{type: :ask} = request) do
    %{
      answer: request.answer,
      answered_by: request.decided_by,
      answered_at: request.completed_at
    }
  end

  # CORE-04 — declared BEFORE the catch-all below, which returns the
  # approve/reject decision fields for every other type. Without this
  # clause a completed choice would render as a decision it never made — a
  # wrong answer, not a missing one.
  defp result(%HumanRequest{type: :choose} = request) do
    %{
      selected_option_ids: request.selected_option_ids,
      free_text: request.answer,
      decided_by: request.decided_by,
      decided_at: request.completed_at
    }
  end

  defp result(%HumanRequest{} = request) do
    %{
      decision: request.decision,
      decided_by: request.decided_by,
      decided_at: request.completed_at
    }
  end

  defp subject(nil), do: nil

  defp subject(%Subject{} = subject) do
    %{type: subject.type, id: subject.id, label: subject.label}
  end

  defp options(nil), do: nil

  defp options(options) when is_list(options) do
    Enum.map(options, &option/1)
  end

  defp option(%Option{} = option) do
    %{
      id: option.id,
      label: option.label,
      description: option.description,
      recommended: option.recommended
    }
  end
end
