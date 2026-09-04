defmodule HumanportWeb.MCP.ParityTest do
  @moduledoc """
  02.1-03-PLAN.md Task 2 — resolves the PROTO-09 concurrency row
  `02.1-01-PLAN.md` left as `unresolved` in its edge probe: a request
  created over MCP and one created over plain HTTP at the SAME moment, by
  two genuinely concurrent processes on SEPARATE database connections, are
  indistinguishable field by field once id, title and timestamps are set
  aside, and neither audit event carries a channel marker.

  Runs on `Humanport.UnsandboxedCase`, never `Humanport.DataCase` (nor
  `HumanportWeb.ConnCase`, which is `DataCase`-backed): under the ordinary
  SQL sandbox in ownership/shared mode, two collaborating processes share
  ONE connection and therefore one transaction, so a "concurrent" pair
  serialises trivially and this test would pass whether or not the
  guarantee it claims to prove is actually there.
  `Humanport.UnsandboxedCase` puts the repo in `:auto` mode instead, so the
  two `Task.async/1` processes below get real, independent connections and
  a genuine race — the SAME pattern `conflict_test.exs` already established.

  Every row this test creates is deleted in `on_exit` — nothing rolls back
  automatically once the sandbox is bypassed. Every count/lookup below is
  scoped by request id, because `audit_events` is append-only (D-14) and
  its rows outlive the test.
  """

  use Humanport.UnsandboxedCase

  require Phoenix.ConnTest

  @endpoint HumanportWeb.Endpoint

  alias Humanport.CloudflareAccessFixtures, as: CfFixtures
  alias Humanport.McpFixtures
  alias Humanport.Requests

  # The rendered-payload keys that MUST differ between the two rows by
  # construction (a fresh id, a distinguishing title so the test itself can
  # tell the two rows apart, and the two independently-generated
  # timestamps) — written out explicitly, per the plan's own instruction,
  # so a future field addition to RequestJSON.show/1 fails this test rather
  # than silently slipping through an implicit filter.
  @excluded_result_keys ~w(id title inserted_at updated_at)

  test "MCP-created and HTTP-created requests, from genuinely concurrent processes on separate connections, are field-by-field indistinguishable and neither audit event carries a channel marker" do
    mcp_conn = Phoenix.ConnTest.build_conn()
    http_conn = Phoenix.ConnTest.build_conn()

    # Identical params on both sides except `title` (each side sets its
    # OWN, on purpose, so the test can tell which created row is which
    # afterwards) — everything else posted identically, so the field-by-field
    # equality below genuinely tests "these two write paths produce the same
    # row," not "these two calls happened to pass the same input."
    shared_params = %{
      "context" => %{"race" => "parity"},
      "risk" => "medium",
      "reversible" => "yes",
      "requester_label" => "parity-test",
      "source" => "parity-test/caller-owned-value"
    }

    mcp_task =
      Task.async(fn ->
        body =
          McpFixtures.call_tool_request(
            "parity-mcp-1",
            "ask",
            Map.put(shared_params, "title", "parity — MCP side")
          )

        resp =
          mcp_conn
          |> put_headers(McpFixtures.headers_for(body))
          |> Phoenix.ConnTest.post("/mcp", Jason.encode!(body))

        response = Phoenix.ConnTest.json_response(resp, 200)
        response["result"]["structuredContent"]["id"]
      end)

    http_task =
      Task.async(fn ->
        params =
          shared_params
          |> Map.put("type", "ask")
          |> Map.put("title", "parity — HTTP side")

        resp = Phoenix.ConnTest.post(http_conn, "/api/v1/requests", params)
        response = Phoenix.ConnTest.json_response(resp, 201)
        response["id"]
      end)

    [mcp_id, http_id] = Task.await_many([mcp_task, http_task], 5_000)

    cleanup_request(mcp_id)
    cleanup_request(http_id)

    {:ok, mcp_request} = Requests.get_request(mcp_id)
    {:ok, http_request} = Requests.get_request(http_id)

    mcp_payload =
      %{request: mcp_request}
      |> HumanportWeb.RequestJSON.show()
      |> Jason.encode!()
      |> Jason.decode!()

    http_payload =
      %{request: http_request}
      |> HumanportWeb.RequestJSON.show()
      |> Jason.encode!()
      |> Jason.decode!()

    # Field by field, once id/title/timestamps are excluded — the exclusion
    # list is @excluded_result_keys, written out explicitly, so a future
    # field addition to RequestJSON.show/1 fails THIS test (forcing a
    # decision about whether the new field is expected to differ) rather
    # than silently slipping through an implicit filter.
    assert Map.drop(mcp_payload, @excluded_result_keys) ==
             Map.drop(http_payload, @excluded_result_keys)

    mcp_audit = audit_row(mcp_id, "request.created")
    http_audit = audit_row(http_id, "request.created")

    assert mcp_audit["source_protocol"] == nil
    assert http_audit["source_protocol"] == nil
    assert mcp_audit["correlation_id"] == nil
    assert http_audit["correlation_id"] == nil

    assert mcp_audit["actor_verified"] == http_audit["actor_verified"]
    assert mcp_audit["actor_method"] == http_audit["actor_method"]
  end

  test "with a genuine Cloudflare Access service-token identity on both sides, the audit facts still match and carry no channel marker" do
    original_resolver = Application.fetch_env!(:humanport, :actor_resolver)
    Application.put_env(:humanport, :actor_resolver, Humanport.Actors.Resolvers.CloudflareAccess)
    on_exit(fn -> Application.put_env(:humanport, :actor_resolver, original_resolver) end)

    mcp_conn = Phoenix.ConnTest.build_conn()
    http_conn = Phoenix.ConnTest.build_conn()

    mcp_token =
      CfFixtures.signed_token(common_name: "agent-service-token-parity.access", without: [:email])

    http_token =
      CfFixtures.signed_token(common_name: "agent-service-token-parity.access", without: [:email])

    mcp_task =
      Task.async(fn ->
        body =
          McpFixtures.call_tool_request("parity-mcp-2", "ask", %{"title" => "parity CF — MCP"})

        resp =
          mcp_conn
          |> Plug.Conn.put_req_header("cf-access-jwt-assertion", mcp_token)
          |> put_headers(McpFixtures.headers_for(body))
          |> Phoenix.ConnTest.post("/mcp", Jason.encode!(body))

        response = Phoenix.ConnTest.json_response(resp, 200)
        response["result"]["structuredContent"]["id"]
      end)

    http_task =
      Task.async(fn ->
        resp =
          http_conn
          |> Plug.Conn.put_req_header("cf-access-jwt-assertion", http_token)
          |> Phoenix.ConnTest.post("/api/v1/requests", %{
            "type" => "ask",
            "title" => "parity CF — HTTP"
          })

        response = Phoenix.ConnTest.json_response(resp, 201)
        response["id"]
      end)

    [mcp_id, http_id] = Task.await_many([mcp_task, http_task], 5_000)

    cleanup_request(mcp_id)
    cleanup_request(http_id)

    mcp_audit = audit_row(mcp_id, "request.created")
    http_audit = audit_row(http_id, "request.created")

    assert mcp_audit["actor_verified"] == true
    assert http_audit["actor_verified"] == true
    assert mcp_audit["actor_method"] == "service_token"
    assert http_audit["actor_method"] == "service_token"
    assert mcp_audit["source_protocol"] == nil
    assert http_audit["source_protocol"] == nil
  end

  test "a choose request created over MCP and one created over plain HTTP, with the same options, are field-by-field indistinguishable and neither audit event carries a channel marker" do
    mcp_conn = Phoenix.ConnTest.build_conn()
    http_conn = Phoenix.ConnTest.build_conn()

    options = [
      %{"id" => "opt-a", "label" => "Roll back"},
      %{"id" => "opt-b", "label" => "Roll forward", "recommended" => true}
    ]

    shared_params = %{
      "options" => options,
      "allow_free_text" => true,
      "max_selections" => 1,
      "requester_label" => "parity-test"
    }

    mcp_task =
      Task.async(fn ->
        body =
          McpFixtures.call_tool_request(
            "parity-choose-mcp",
            "choose",
            Map.put(shared_params, "title", "parity choose — MCP side")
          )

        resp =
          mcp_conn
          |> put_headers(McpFixtures.headers_for(body))
          |> Phoenix.ConnTest.post("/mcp", Jason.encode!(body))

        response = Phoenix.ConnTest.json_response(resp, 200)
        response["result"]["structuredContent"]["id"]
      end)

    http_task =
      Task.async(fn ->
        params = Map.put(shared_params, "title", "parity choose — HTTP side")
        resp = Phoenix.ConnTest.post(http_conn, "/api/v1/requests", params)
        response = Phoenix.ConnTest.json_response(resp, 201)
        response["id"]
      end)

    [mcp_id, http_id] = Task.await_many([mcp_task, http_task], 5_000)

    cleanup_request(mcp_id)
    cleanup_request(http_id)

    {:ok, mcp_request} = Requests.get_request(mcp_id)
    {:ok, http_request} = Requests.get_request(http_id)

    assert mcp_request.type == :choose
    assert http_request.type == :choose

    mcp_payload =
      %{request: mcp_request}
      |> HumanportWeb.RequestJSON.show()
      |> Jason.encode!()
      |> Jason.decode!()

    http_payload =
      %{request: http_request}
      |> HumanportWeb.RequestJSON.show()
      |> Jason.encode!()
      |> Jason.decode!()

    assert Map.drop(mcp_payload, @excluded_result_keys) ==
             Map.drop(http_payload, @excluded_result_keys)

    mcp_audit = audit_row(mcp_id, "request.created")
    http_audit = audit_row(http_id, "request.created")

    assert mcp_audit["source_protocol"] == nil
    assert http_audit["source_protocol"] == nil
    assert mcp_audit["correlation_id"] == nil
    assert http_audit["correlation_id"] == nil
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
  end

  defp cleanup_request(id) do
    on_exit(fn ->
      Repo.query!("DELETE FROM human_requests WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)
  end

  defp audit_row(request_id, event_type) do
    %Postgrex.Result{columns: columns, rows: [row]} =
      Repo.query!(
        "SELECT source_protocol, correlation_id, actor_verified, actor_method " <>
          "FROM audit_events WHERE request_id = $1 AND event_type = $2",
        [Ecto.UUID.dump!(request_id), event_type]
      )

    columns |> Enum.zip(row) |> Map.new()
  end
end
