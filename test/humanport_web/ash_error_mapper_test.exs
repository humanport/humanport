defmodule HumanportWeb.AshErrorMapperTest do
  @moduledoc """
  02.1-02-PLAN.md Task 2 — the shared not-found / already-decided /
  malformed taxonomy `HumanportWeb.FallbackController` (HTTP, 409/422) and
  `HumanportWeb.McpController` (JSON-RPC tool-result, `isError: true`) both
  classify domain errors through, proven once here rather than by
  inspection of either caller. The already-decided (conflict) case must
  never collapse into the malformed (invalid) case — that collapse is what
  would tell an agent to keep retrying something already decided.
  """

  use Humanport.DataCase, async: false

  import Humanport.Fixtures

  alias Humanport.Requests
  alias Humanport.Requests.HumanRequest
  alias HumanportWeb.AshErrorMapper

  describe "classify/1 — the three distinguishable outcomes" do
    test "a request that does not exist classifies as :not_found" do
      assert {:error, error} = Requests.get_request(Ash.UUID.generate())
      assert {:not_found, message} = AshErrorMapper.classify(error)
      assert message =~ "not found"
    end

    test "responding to an already-answered request classifies as :conflict, never :invalid" do
      request = request_fixture(%{type: :ask})
      actor = default_actor()

      assert {:ok, _first} = Requests.answer(request, "first answer", actor)
      assert {:ok, already_answered} = Requests.get_request(request.id)

      assert {:error, error} = Requests.answer(already_answered, "second answer", actor)

      assert {:conflict, message} = AshErrorMapper.classify(error)
      assert message =~ "already answered"
    end

    test "a type/action mismatch classifies as :invalid, never :conflict or :not_found" do
      assert {:error, error} =
               Requests.answer(%HumanRequest{type: :approve}, "x", default_actor())

      assert {:invalid, message} = AshErrorMapper.classify(error)
      assert message =~ "cannot be answered"
    end

    test "an unimplemented request type classifies as :not_implemented, distinct from :invalid" do
      # CORE-04 — `choose` is implemented now; `escalate` (Phase 5) is the
      # one genuinely unimplemented type left.
      assert {:error, error} =
               Requests.submit(%{"type" => "escalate", "title" => "x"}, default_actor())

      assert {:not_implemented, message} = AshErrorMapper.classify(error)
      assert message =~ "answers only"
    end
  end

  describe "details/1 — field-level detail, only for the generic :invalid case" do
    test "a missing required field returns field-level details" do
      assert {:error, error} = Requests.submit(%{"type" => "ask"}, default_actor())
      assert {:invalid, _message} = AshErrorMapper.classify(error)
      assert [%{field: :title} | _] = AshErrorMapper.details(error)
    end

    test "a not-found error carries no field-level details" do
      assert {:error, error} = Requests.get_request(Ash.UUID.generate())
      assert AshErrorMapper.details(error) == []
    end
  end
end
