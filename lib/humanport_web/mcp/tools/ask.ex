defmodule HumanportWeb.MCP.Tools.Ask do
  @moduledoc """
  02.1-02-PLAN.md Task 1 — the phase's tracer tool. Wire name `ask`.

  `call/2` mirrors `HumanportWeb.RequestController.create/2`'s own shape
  exactly: `with {:ok, request} <- Requests.submit(params, actor)`, and
  nothing else — no changeset, no direct `Ash.*` call. That is what makes
  the PROTO-09 one-write-path guarantee structural rather than asserted
  (T-02.1-01, `02.1-PATTERNS.md`).

  The success result's `structuredContent` is
  `HumanportWeb.RequestJSON.show/1`'s own output for the created record —
  the HTTP surface's own wire shape, reused rather than re-rendered.

  The `source` argument flows through untouched (D-04, D-11) — this module
  writes nothing into it and adds no channel marker to the created row or
  its audit event; a request created here must be unfindable as
  MCP-created by anyone reading the database (PROTO-09).
  """

  @behaviour HumanportWeb.MCP.Tool

  alias Humanport.Actors.Actor
  alias Humanport.Requests

  @impl true
  def name, do: "ask"

  @impl true
  def definition do
    %{
      "name" => name(),
      "title" => "Ask a human",
      "description" =>
        "Creates a HumanPort request asking a human to answer a free-text question. " <>
          "Returns immediately with the created, still-pending request; use the " <>
          "check or await tools (02.1-03) to learn of the answer.",
      "annotations" => %{
        "title" => "Ask a human",
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => true
      },
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "The question, in one line."},
          "description" => %{"type" => "string"},
          "context" => %{"type" => "object"},
          "subject" => %{
            "type" => "object",
            "properties" => %{
              "type" => %{"type" => "string"},
              "id" => %{"type" => "string"},
              "label" => %{"type" => "string"}
            }
          },
          "source" => %{
            "type" => "string",
            "description" => "The caller's own correlation value, carried through unchanged."
          },
          "external_correlation" => %{"type" => "string"},
          "requester_label" => %{"type" => "string"},
          "risk" => %{"type" => "string", "enum" => ["high", "medium", "low"]},
          "reversible" => %{"type" => "string"}
        },
        "required" => ["title"]
      }
    }
  end

  @impl true
  def call(arguments, %Actor{} = actor) when is_map(arguments) do
    params = Map.put(arguments, "type", "ask")

    with {:ok, request} <- Requests.submit(params, actor) do
      {:ok,
       %{
         content: [
           %{
             "type" => "text",
             "text" =>
               "Created ask request req/#{HumanportWeb.RequestLive.short_id(request.id)} (pending)."
           }
         ],
         structured_content: HumanportWeb.RequestJSON.show(%{request: request}),
         is_error: false
       }}
    end
  end
end
