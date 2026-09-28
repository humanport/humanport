defmodule HumanportWeb.MCP.Tools.Approve do
  @moduledoc """
  02.1-03-PLAN.md Task 2 — the SECOND CREATION tool. Wire name `approve`.

  This tool asks a human to approve something. **It does not approve
  anything.** `call/2` mirrors `HumanportWeb.MCP.Tools.Ask.call/2` and
  `HumanportWeb.RequestController.create/2` exactly:
  `with {:ok, request} <- Requests.submit(params, actor)`, differing ONLY in
  the fixed `"type" => "approve"` it puts into `params` — no changeset, no
  direct `Ash.*` call, no second write path (PROTO-09, D-10).

  This module MUST NEVER call the domain's own decision-making functions,
  MUST NEVER set the decision attribute on a request, and MUST NEVER
  transition a request's state. Those are the human's to make, through the
  web inbox or `POST /api/v1/requests/:id/respond` — a tool that could grant
  its own approval is not a gate (§54.8). This is the single most plausible
  misreading in the phase (T-02.1-14), which is why it is written down here
  AND grepped for in this task's own `<verify>` rather than left to good
  sense.

  The success result's `structuredContent` is `HumanportWeb.RequestJSON.show/1`'s
  own output for the created record, exactly like `ask` — the created row's
  `decision` is null and `completed_at` is null, because nothing here ever
  decides anything.
  """

  @behaviour HumanportWeb.MCP.Tool

  alias Humanport.Actors.Actor
  alias Humanport.Requests

  @impl true
  def name, do: "approve"

  @impl true
  def definition do
    %{
      "name" => name(),
      "title" => "Ask a human to approve",
      "description" =>
        "Creates a HumanPort request asking a human to approve or reject an action. " <>
          "Returns immediately with the created, still-pending request — this tool " <>
          "does NOT itself grant or deny the approval. Use the check or await tools " <>
          "to learn of the human's decision.",
      "annotations" => %{
        "title" => "Ask a human to approve",
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => true
      },
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{
            "type" => "string",
            "description" => "The action to approve, in one line."
          },
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
    params = Map.put(arguments, "type", "approve")

    with {:ok, request} <- Requests.submit(params, actor) do
      {:ok,
       %{
         content: [
           %{
             "type" => "text",
             "text" =>
               "Created approve request req/#{HumanportWeb.RequestLive.short_id(request.id)} (pending)."
           }
         ],
         structured_content: HumanportWeb.RequestJSON.show(%{request: request}),
         is_error: false
       }}
    end
  end
end
