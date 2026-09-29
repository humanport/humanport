defmodule Humanport.Requests.DeadlineTest do
  @moduledoc """
  ROUTE-* — a request with a `deadline_at` is scheduled to expire in the same
  transaction that creates it; the `ExpireRequest` job expires it atomically
  and audits it once the deadline has passed, leaves a decided request
  alone, and snoozes if it runs early; and a decision after the deadline is
  refused even before the job has run.
  """

  use Humanport.DataCase, async: true
  use Oban.Testing, repo: Humanport.Repo

  import Humanport.Fixtures

  alias Humanport.Requests
  alias Humanport.Requests.Workers.ExpireRequest

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # Moves a pending request's deadline into the past the way time would —
  # outside every Ash action. The terminal-row trigger allows writes to a
  # pending row, and `deadline_at` is not part of the content fingerprint.
  defp pass_deadline(request) do
    Repo.query!("UPDATE human_requests SET deadline_at = $1 WHERE id = $2", [
      DateTime.add(DateTime.utc_now(), -1, :second),
      Ecto.UUID.dump!(request.id)
    ])

    {:ok, reloaded} = Requests.get_request(request.id)
    reloaded
  end

  defp event_types(request_id) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.all(
      from(e in "audit_events",
        where: e.request_id == ^request_id_bin,
        select: e.event_type,
        order_by: e.occurred_at
      )
    )
  end

  describe "at submit" do
    test "a request with a deadline schedules its own expiry" do
      deadline_at = in_seconds(3600)
      request = request_fixture(%{deadline_at: deadline_at})

      assert DateTime.compare(request.deadline_at, deadline_at) == :eq

      assert_enqueued(
        worker: ExpireRequest,
        args: %{"request_id" => request.id},
        scheduled_at: deadline_at
      )
    end

    test "a request without a deadline schedules nothing" do
      request_fixture()
      refute_enqueued(worker: ExpireRequest)
    end

    test "a deadline in the past is refused and nothing is written" do
      assert {:error, %Ash.Error.Invalid{}} =
               Requests.submit(
                 %{type: :ask, title: "Too late", deadline_at: in_seconds(-60)},
                 default_actor()
               )

      assert {:ok, []} = Requests.list_requests()
      refute_enqueued(worker: ExpireRequest)
    end
  end

  describe "the expiry job" do
    test "expires a pending request once its deadline has passed, and audits it" do
      request =
        request_fixture(%{type: :approve, deadline_at: in_seconds(3600)}) |> pass_deadline()

      assert :ok = perform_job(ExpireRequest, %{"request_id" => request.id})

      {:ok, expired} = Requests.get_request(request.id)
      assert expired.state == :expired
      refute is_nil(expired.completed_at)
      assert expired.decided_by["type"] == "system"
      assert event_types(request.id) == ["request.created", "request.expired"]
    end

    test "leaves a request decided in time alone" do
      request = request_fixture(%{type: :approve, deadline_at: in_seconds(3600)})
      {:ok, _approved} = Requests.approve(request, default_actor())

      assert :ok = perform_job(ExpireRequest, %{"request_id" => request.id})
      assert {:ok, %{state: :approved}} = Requests.get_request(request.id)
    end

    test "snoozes when it runs before the deadline" do
      request = request_fixture(%{deadline_at: in_seconds(120)})

      assert {:snooze, seconds} = perform_job(ExpireRequest, %{"request_id" => request.id})
      assert seconds > 0 and seconds <= 120
      assert {:ok, %{state: :pending}} = Requests.get_request(request.id)
    end

    test "running twice is harmless" do
      request = request_fixture(%{deadline_at: in_seconds(3600)}) |> pass_deadline()

      assert :ok = perform_job(ExpireRequest, %{"request_id" => request.id})
      assert :ok = perform_job(ExpireRequest, %{"request_id" => request.id})
      assert event_types(request.id) == ["request.created", "request.expired"]
    end
  end

  describe "deciding after the deadline" do
    test "is refused before the job has run, and records nothing" do
      request =
        request_fixture(%{type: :approve, deadline_at: in_seconds(3600)}) |> pass_deadline()

      assert {:error, %Ash.Error.Invalid{errors: [%Humanport.Requests.Errors.DeadlinePassed{}]}} =
               Requests.approve(request, default_actor())

      assert {:ok, %{state: :pending}} = Requests.get_request(request.id)
      assert event_types(request.id) == ["request.created"]
    end

    test "an expired request is a conflict to answer" do
      request = request_fixture(%{deadline_at: in_seconds(3600)}) |> pass_deadline()
      :ok = perform_job(ExpireRequest, %{"request_id" => request.id})
      {:ok, expired} = Requests.get_request(request.id)

      assert {:error, _error} = Requests.answer(expired, "too late", default_actor())
      assert {:ok, %{state: :expired, answer: nil}} = Requests.get_request(request.id)
    end
  end
end
