defmodule HumanportWeb.Mcp.SchemaOracleTest do
  @moduledoc """
  Proves `Humanport.McpSchema` is not a no-op (D-08a, `02.1-CONTEXT.md`).
  Every assertion here runs the validator, not merely reads the helper — a
  run in which all three `refute_valid!/2` assertions below were deleted
  would turn this file green trivially, which is exactly the failure this
  file exists to catch. See `priv/mcp/README.md` for the draft-07
  substitution this module relies on.
  """

  use ExUnit.Case, async: true

  alias Humanport.{McpFixtures, McpSchema}
  alias Humanport.McpSchema.{DigestMismatchError, UnexpectedlyValidError, UnknownDefinitionError}

  describe "assert_valid!/2 — well-formed payloads" do
    test "a DiscoverResult carrying every required field passes" do
      payload = %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        # $defs-referenced definition (ServerCapabilities via $ref) — proves
        # the resolver actually follows #/$defs/… rather than validating
        # vacuously against an unresolved pointer.
        "capabilities" => %{"tools" => %{"listChanged" => false}},
        "cacheScope" => "public",
        "ttlMs" => 0
      }

      assert :ok = McpSchema.assert_valid!(payload, "DiscoverResult")
    end

    test "a ListToolsResult carrying every required field passes" do
      payload = %{
        "resultType" => "complete",
        "cacheScope" => "public",
        "tools" => [],
        "ttlMs" => 0
      }

      assert :ok = McpSchema.assert_valid!(payload, "ListToolsResult")
    end

    test "a CallToolResult whose content exercises the $defs-referenced ContentBlock/TextContent definitions passes" do
      payload = %{
        "resultType" => "complete",
        # ContentBlock -> TextContent, both resolved through #/$defs/… — the
        # nested $ref chain a broken resolver would fail to follow.
        "content" => [%{"type" => "text", "text" => "hello from the oracle"}]
      }

      assert :ok = McpSchema.assert_valid!(payload, "CallToolResult")
    end
  end

  describe "refute_valid!/2 — the oracle demonstrably rejects malformed payloads" do
    test "a DiscoverResult with supportedVersions removed is rejected" do
      payload = %{
        "resultType" => "complete",
        "capabilities" => %{},
        "cacheScope" => "public",
        "ttlMs" => 0
      }

      refute Map.has_key?(payload, "supportedVersions")
      assert :ok = McpSchema.refute_valid!(payload, "DiscoverResult")
    end

    test "a ListToolsResult with ttlMs removed is rejected" do
      payload = %{
        "resultType" => "complete",
        "cacheScope" => "public",
        "tools" => []
      }

      refute Map.has_key?(payload, "ttlMs")
      assert :ok = McpSchema.refute_valid!(payload, "ListToolsResult")
    end

    test "a CallToolResult with content removed is rejected" do
      payload = %{"resultType" => "complete"}

      refute Map.has_key?(payload, "content")
      assert :ok = McpSchema.refute_valid!(payload, "CallToolResult")
    end
  end

  describe "definition lookups" do
    test "assert_valid!/2 raises a module-defined exception for an unknown definition name, rather than validating against nothing" do
      assert_raise UnknownDefinitionError, ~r/NoSuchDefinition/, fn ->
        McpSchema.assert_valid!(%{}, "NoSuchDefinition")
      end
    end

    test "refute_valid!/2 raises the same module-defined exception for an unknown definition name" do
      assert_raise UnknownDefinitionError, ~r/NoSuchDefinition/, fn ->
        McpSchema.refute_valid!(%{}, "NoSuchDefinition")
      end
    end
  end

  describe "refute_valid!/2's own failure mode" do
    test "raises UnexpectedlyValidError, not a bare match failure, when the payload validates anyway" do
      well_formed = %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{},
        "cacheScope" => "public",
        "ttlMs" => 0
      }

      assert_raise UnexpectedlyValidError, fn ->
        McpSchema.refute_valid!(well_formed, "DiscoverResult")
      end
    end
  end

  describe "Humanport.McpFixtures — fixture bodies validate against the vendored schema (02.1-01 Task 3 Part C)" do
    test "discover_request/1 validates against DiscoverRequest" do
      assert :ok =
               McpFixtures.discover_request("discover-1")
               |> McpSchema.assert_valid!("DiscoverRequest")
    end

    test "list_tools_request/1 validates against ListToolsRequest" do
      assert :ok =
               McpFixtures.list_tools_request(1)
               |> McpSchema.assert_valid!("ListToolsRequest")
    end

    test "call_tool_request/3 validates against CallToolRequest" do
      assert :ok =
               McpFixtures.call_tool_request(2, "ask", %{"question" => "proceed?"})
               |> McpSchema.assert_valid!("CallToolRequest")
    end
  end

  describe "Humanport.McpFixtures — required _meta keys and derived headers" do
    test "every fixture body carries both required _meta keys" do
      for body <- [
            McpFixtures.discover_request("d-1"),
            McpFixtures.list_tools_request("l-1"),
            McpFixtures.call_tool_request("c-1", "ask", %{})
          ] do
        meta = body["params"]["_meta"]
        assert Map.has_key?(meta, "io.modelcontextprotocol/protocolVersion")
        assert Map.has_key?(meta, "io.modelcontextprotocol/clientCapabilities")
      end
    end

    test "headers_for/1 mirrors the body's protocol version and method, and the tool name for tools/call only" do
      discover = McpFixtures.discover_request("d-2")
      discover_headers = McpFixtures.headers_for(discover)

      assert {"mcp-protocol-version", McpFixtures.protocol_version()} in discover_headers
      assert {"mcp-method", "server/discover"} in discover_headers
      refute Enum.any?(discover_headers, fn {k, _v} -> k == "mcp-name" end)

      call = McpFixtures.call_tool_request("c-2", "approve", %{"id" => "abc"})
      call_headers = McpFixtures.headers_for(call)

      assert {"mcp-method", "tools/call"} in call_headers
      assert {"mcp-name", "approve"} in call_headers
    end
  end

  describe "digest verification (Humanport.McpSchema.verify_digest!/2 — pure, exercised directly so the real vendored file is never corrupted by a test)" do
    test "passes silently when the contents match the pinned digest" do
      real_contents = File.read!(McpSchema.vendored_path())
      real_sums = File.read!(McpSchema.sha256sums_path())

      assert :ok = McpSchema.verify_digest!(real_contents, real_sums)
    end

    test "raises a module-defined exception, not a bare MatchError, when the digest does not match" do
      tampered_contents = "not the schema you pinned"
      real_sums = File.read!(McpSchema.sha256sums_path())

      assert_raise DigestMismatchError, ~r/digest mismatch/, fn ->
        McpSchema.verify_digest!(tampered_contents, real_sums)
      end
    end
  end
end
