defmodule HumanportWeb.RequestJSON do
  @moduledoc """
  The D-03/D-22 wire shape, fixed by the Task 1 checkpoint decision: no
  envelope, both the coarse `status` and the canonical `state` at different
  resolutions, `result` null while pending.
  """

  alias Humanport.Requests.HumanRequest
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
end
