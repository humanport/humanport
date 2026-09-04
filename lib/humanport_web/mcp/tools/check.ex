defmodule HumanportWeb.MCP.Tools.Check do
  @moduledoc """
  02.1-03-PLAN.md Task 2 — the immediate glance. Wire name `check`.

  `call/2` calls `Humanport.Requests.get_request/1` and nothing else — no
  changeset, no direct data-layer call, no wait, no subscription. It is
  D-01's immediate half: the zero-wait branch of the exact same primitive
  `HumanportWeb.MCP.Tools.Await` (02.1-03-PLAN.md Task 3) uses, reached
  without ever calling `HumanportWeb.RequestWaiting.await/4` at all — a
  glance has nothing to wait on.

  The success result's `structuredContent` is
  `HumanportWeb.RequestJSON.show/1`'s own output — the HTTP surface's own
  wire shape, reused rather than re-rendered — and its `_meta` carries the
  key `app.humanport/wait` with two integers and nothing else: `waited_ms`
  (always `0` here — `check` never waits, whatever the request's state) and
  `pending_for_ms` (the elapsed time since the request was created, or until
  it completed if it already has). Two integers, no request content, no
  actor identity, no internal state — result metadata travels further and is
  inspected less carefully than a result body (T-02.1-12).

  A missing request is a TOOL-originated error (`isError: true` inside a
  successful result), never a JSON-RPC error response — the same
  classification `HumanportWeb.MCP.Tools.Ask` already established via
  `HumanportWeb.AshErrorMapper`, reused here rather than copied.
  """

  @behaviour HumanportWeb.MCP.Tool

  alias Humanport.Actors.Actor
  alias Humanport.Requests

  @impl true
  def name, do: "check"

  @impl true
  def definition do
    %{
      "name" => name(),
      "title" => "Check a request",
      "description" =>
        "Reads a HumanPort request's current state without waiting — the immediate " <>
          "glance. Use the await tool instead if you want to hold until the request " <>
          "is answered or a timeout elapses.",
      "annotations" => %{
        "title" => "Check a request",
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      },
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The request's id."}
        },
        "required" => ["id"]
      }
    }
  end

  @impl true
  def call(%{"id" => id}, %Actor{}) when is_binary(id) do
    case Requests.get_request(id) do
      {:ok, request} -> {:ok, success_result(request)}
      {:error, error} -> {:error, error}
    end
  end

  def call(_arguments, %Actor{}), do: {:error, missing_id_error()}

  @doc false
  # Shared with HumanportWeb.MCP.Tools.Await (02.1-03-PLAN.md Task 3) — the
  # SAME `app.humanport/wait` shape, `waited_ms` differing (always 0 here,
  # positive there). Kept as a small independent private helper rather than
  # a new shared module: two integers formatted one way is not the kind of
  # domain logic D-10/RequestWaiting exists to keep singular, and the plan's
  # own files_modified list for both tasks names no such module.
  def wait_meta(waited_ms, request) do
    %{
      "app.humanport/wait" => %{
        "waited_ms" => waited_ms,
        "pending_for_ms" => pending_for_ms(request)
      }
    }
  end

  @doc false
  def pending_for_ms(request) do
    reference = request.completed_at || DateTime.utc_now()
    DateTime.diff(reference, request.inserted_at, :millisecond)
  end

  defp success_result(request) do
    %{
      content: [
        %{
          "type" => "text",
          "text" => "req/#{HumanportWeb.RequestLive.short_id(request.id)} is #{request.state}."
        }
      ],
      structured_content: HumanportWeb.RequestJSON.show(%{request: request}),
      is_error: false,
      meta: wait_meta(0, request)
    }
  end

  defp missing_id_error do
    Ash.Error.Invalid.exception(
      errors: [
        Ash.Error.Changes.InvalidAttribute.exception(field: :id, message: "id is required")
      ]
    )
  end
end
