defmodule Humanport.Requests.ContentHashTest do
  @moduledoc """
  SEC-08 / §54.8 — every request is fingerprinted at submit, every decision
  is bound to the fingerprint of the content the decider was shown, a
  decision on content that is not the request's current, unaltered content
  is refused with nothing recorded, and `verify_content/1` detects content
  altered outside the domain.
  """

  use Humanport.DataCase, async: true

  import Humanport.Fixtures

  alias Humanport.Requests
  alias Humanport.Requests.ContentHash

  defp audit_metadata(request_id) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.all(
      from(e in "audit_events",
        where: e.request_id == ^request_id_bin,
        select: {e.event_type, e.metadata},
        order_by: e.occurred_at
      )
    )
  end

  # Alters a pending row's content the way a direct database write would —
  # outside every Ash action. The terminal-row trigger only blocks writes to
  # decided rows, so a pending row can be changed.
  defp tamper_title(request, title) do
    Repo.query!("UPDATE human_requests SET title = $1 WHERE id = $2", [
      title,
      Ecto.UUID.dump!(request.id)
    ])
  end

  describe "at submit" do
    test "the request is fingerprinted and the created event records the fingerprint" do
      request = request_fixture(%{title: "Deploy 1.4?", context: %{env: "prod", replicas: 3}})

      assert "sha256:" <> hex = request.content_hash
      assert byte_size(hex) == 64

      {:ok, reloaded} = Requests.get_request(request.id)
      assert ContentHash.compute(reloaded) == request.content_hash

      assert [{"request.created", %{"content_hash" => recorded}}] = audit_metadata(request.id)
      assert recorded == request.content_hash
    end

    test "different content gives a different fingerprint; the same content the same one" do
      a = request_fixture(%{title: "Deploy 1.4?"})
      b = request_fixture(%{title: "Deploy 1.5?"})
      c = request_fixture(%{title: "Deploy 1.4?"})

      refute a.content_hash == b.content_hash
      assert a.content_hash == c.content_hash
    end

    test "choose options are part of the fingerprint" do
      a = choose_request_fixture(%{options: [%{id: "x", label: "X"}]})
      b = choose_request_fixture(%{options: [%{id: "x", label: "Y"}]})

      refute a.content_hash == b.content_hash
    end
  end

  describe "deciding" do
    test "approve records the fingerprint of the content that was shown" do
      request = request_fixture(%{type: :approve, title: "Deploy 1.4?"})

      assert {:ok, approved} = Requests.approve(request, default_actor())
      assert approved.decided_content_hash == request.content_hash

      assert [_created, {"request.approved", %{"content_hash" => recorded}}] =
               audit_metadata(request.id)

      assert recorded == request.content_hash
      assert :ok = Requests.verify_content(approved)
    end

    test "answer, reject and choose record it too" do
      ask = request_fixture(%{title: "Which one?"})
      {:ok, answered} = Requests.answer(ask, "this one", default_actor())
      assert answered.decided_content_hash == ask.content_hash

      approve = request_fixture(%{type: :approve})
      {:ok, rejected} = Requests.reject(approve, default_actor())
      assert rejected.decided_content_hash == approve.content_hash

      choose = choose_request_fixture()
      {:ok, chosen} = Requests.choose(choose, %{selected_option_ids: ["opt-a"]}, default_actor())
      assert chosen.decided_content_hash == choose.content_hash
    end

    test "a presented fingerprint that does not match is refused and nothing is recorded" do
      request = request_fixture(%{type: :approve, title: "Deploy 1.4?"})

      assert {:error, error} =
               Requests.approve(request, default_actor(),
                 content_hash: "sha256:" <> String.duplicate("0", 64)
               )

      assert %Ash.Error.Invalid{errors: [%Humanport.Requests.Errors.ContentChanged{}]} = error
      assert {:ok, %{state: :pending}} = Requests.get_request(request.id)
      assert [{"request.created", _}] = audit_metadata(request.id)
    end

    test "content altered after it was shown is refused, even with the decider's own copy" do
      shown = request_fixture(%{type: :approve, title: "Deploy 1.4 to staging?"})
      tamper_title(shown, "Deploy 1.4 to prod?")

      assert {:error, %Ash.Error.Invalid{errors: [%Humanport.Requests.Errors.ContentChanged{}]}} =
               Requests.approve(shown, default_actor())

      assert {:ok, %{state: :pending}} = Requests.get_request(shown.id)
    end

    test "content altered is refused even when the decider loads the altered copy" do
      request = request_fixture(%{type: :approve, title: "Deploy 1.4 to staging?"})
      tamper_title(request, "Deploy 1.4 to prod?")
      {:ok, altered} = Requests.get_request(request.id)

      assert {:error, %Ash.Error.Invalid{errors: [%Humanport.Requests.Errors.ContentChanged{}]}} =
               Requests.approve(altered, default_actor())
    end
  end

  describe "verify_content/1" do
    test "detects content altered outside the domain" do
      request = request_fixture(%{title: "Deploy 1.4 to staging?"})
      assert :ok = Requests.verify_content(request)

      tamper_title(request, "Deploy 1.4 to prod?")
      {:ok, altered} = Requests.get_request(request.id)

      assert {:error, :content_mismatch} = Requests.verify_content(altered)
    end
  end
end
