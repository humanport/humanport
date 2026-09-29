defmodule Humanport.Requests.Workers.ExpireRequest do
  @moduledoc """
  ROUTE-* — expires a request whose deadline passed with no decision.
  Inserted by `Humanport.Requests.submit/2` in the same transaction as the
  request itself, scheduled for its `deadline_at`, so a request with a
  deadline can never exist without the job that ends it.

  Idempotent by construction: a request that is already terminal (decided
  in time, or expired by an earlier attempt) is left alone, and a decision
  racing the expiry loses or wins in the atomic `:expire` UPDATE, never
  both. A job that runs early (clock skew between nodes) snoozes until the
  deadline rather than expiring anything ahead of time.
  """

  use Oban.Worker, queue: :deadlines, max_attempts: 10

  alias Humanport.Requests

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"request_id" => request_id}}) do
    case Requests.get_request(request_id) do
      {:ok, %{state: :pending} = request} -> expire_when_due(request)
      {:ok, _terminal} -> :ok
      {:error, _not_found} -> :ok
    end
  end

  defp expire_when_due(%{deadline_at: nil}), do: :ok

  defp expire_when_due(%{deadline_at: deadline_at} = request) do
    case DateTime.diff(deadline_at, DateTime.utc_now(), :second) do
      seconds when seconds > 0 ->
        {:snooze, seconds}

      _due ->
        case Requests.expire(request) do
          {:ok, _expired} -> :ok
          {:error, error} -> if lost_race?(error), do: :ok, else: {:error, error}
        end
    end
  end

  # Someone decided the request between our read and our UPDATE: the atomic
  # transition guard refused the expiry. Nothing left to do.
  defp lost_race?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))
  end

  defp lost_race?(_error), do: false
end
