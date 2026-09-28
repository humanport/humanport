defmodule HumanportWeb.MCP.Tools.Choose do
  @moduledoc """
  02.1-05-PLAN.md Task 1 — the THIRD creation tool. Wire name `choose`.

  `call/2` mirrors `HumanportWeb.MCP.Tools.Ask.call/2` and
  `HumanportWeb.MCP.Tools.Approve.call/2` exactly:
  `with {:ok, request} <- Requests.submit(params, actor)` — no changeset, no
  direct `Ash.*` call, no second write path (PROTO-09, D-10). It differs
  from the other two only in the extra arguments it accepts (`options`,
  `allow_free_text`, `max_selections`) and the fixed `"type" => "choose"` it
  puts into `params`.

  This module MUST NEVER build a selection itself — the answered-state
  attribute is not accepted here and is not even a valid input to
  `:submit` (`02.1-04-PLAN.md`'s own guarantee) — and MUST NEVER mark its
  own channel
  anywhere a request or an audit event can be read from: not in `source`
  (D-11), not in the audit event's protocol column. A request created here
  must be unfindable as MCP-created by anyone reading the database
  (PROTO-09).

  The success result's `structuredContent` is `HumanportWeb.RequestJSON.show/1`'s
  own output for the created record — which now renders `options`,
  `allow_free_text` and `max_selections` (`02.1-04`), so the verbatim option
  round trip is observable to the caller in the very response that created
  them.
  """

  @behaviour HumanportWeb.MCP.Tool

  alias Humanport.Actors.Actor
  alias Humanport.Requests

  @impl true
  def name, do: "choose"

  @impl true
  def definition do
    %{
      "name" => name(),
      "title" => "Ask a human to choose",
      "description" =>
        "Creates a HumanPort request asking a human to pick from a set of named options. " <>
          "Returns immediately with the created, still-pending request; use the " <>
          "check or await tools to learn of the human's choice. The result is always " <>
          "a list of chosen option ids, even when only one may be chosen.",
      "annotations" => %{
        "title" => "Ask a human to choose",
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
            "description" => "The decision to make, in one line."
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
          "reversible" => %{"type" => "string"},
          "options" => %{
            "type" => "array",
            "description" =>
              "The named paths a human may pick from. Stored and returned unchanged — " <>
                "not interpreted, normalised, sorted or deduplicated. At least one option " <>
                "is required; a request with no options is an ask or approve request instead.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{
                  "type" => "string",
                  "description" => "The stable id this option is chosen by. Caller-owned."
                },
                "label" => %{
                  "type" => "string",
                  "description" => "The human-facing text for this option."
                },
                "description" => %{"type" => "string"},
                "recommended" => %{
                  "type" => "boolean",
                  "description" =>
                    "Advice to the human that this option looks preferable, shown as a " <>
                      "suggestion beside the option. It is NEVER a default and is NEVER " <>
                      "pre-selected — a human who submits without choosing submits nothing, " <>
                      "regardless of this flag. Do not rely on this flag to steer the " <>
                      "outcome; it changes only what the human sees described as suggested."
                }
              },
              "required" => ["id", "label"]
            }
          },
          "allow_free_text" => %{
            "type" => "boolean",
            "description" =>
              "When true, the human may answer with free text instead of an option id."
          },
          "max_selections" => %{
            "type" => "integer",
            "description" => "The most options the human may select at once. Defaults to 1."
          }
        },
        "required" => ["title"]
      }
    }
  end

  @impl true
  def call(arguments, %Actor{} = actor) when is_map(arguments) do
    params = Map.put(arguments, "type", "choose")

    with {:ok, request} <- Requests.submit(params, actor) do
      {:ok,
       %{
         content: [
           %{
             "type" => "text",
             "text" =>
               "Created choose request req/#{HumanportWeb.RequestLive.short_id(request.id)} (pending)."
           }
         ],
         structured_content: HumanportWeb.RequestJSON.show(%{request: request}),
         is_error: false
       }}
    end
  end
end
