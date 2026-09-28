defmodule HumanportWeb.HumanPortUITest do
  @moduledoc """
  Render tests for the nine `HumanPort.UI.*` display components (plan
  01-05, Task 1). Every documented state is exercised, including the two
  held-out UI-state backstops the UI-SPEC calls out: a title far longer
  than the pane width (`RequestCard`) and a wide pre-formatted context
  block (`ContextBlock`).
  """

  use HumanportWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HumanPort.UI.ActorIdentity
  alias HumanPort.UI.AgentBadge
  alias HumanPort.UI.ChoiceCard
  alias HumanPort.UI.ContextBlock
  alias HumanPort.UI.FilterTabs
  alias HumanPort.UI.MetaList
  alias HumanPort.UI.PaneHeader
  alias HumanPort.UI.RequestCard
  alias HumanPort.UI.RequestTimeline
  alias HumanPort.UI.RiskBadge

  describe "PaneHeader" do
    test "root form renders the working-directory line and the stats slot" do
      html =
        render_component(&PaneHeader.pane_header/1, %{
          form: :root,
          stats: [%{inner_block: fn _, _ -> "3 open" end}]
        })

      assert html =~ "humanport"
      assert html =~ "~/requests"
    end

    test "detail form renders the back control and the request short id" do
      html = render_component(&PaneHeader.pane_header/1, %{form: :detail, short_id: "c1e5f"})

      assert html =~ "req/c1e5f"
      assert html =~ "Esc"
    end

    test "notice slot is unused in Phase 1 and renders nothing when absent" do
      html = render_component(&PaneHeader.pane_header/1, %{form: :root})
      refute html =~ "<p"
    end
  end

  describe "FilterTabs" do
    test "renders exactly two tabs" do
      html = render_component(&FilterTabs.filter_tabs/1, %{active: :open})

      assert html =~ ~s(role="tablist")
      assert Regex.scan(~r/role="tab"/, html) |> length() == 2
    end

    test "the active tab carries aria-selected true and tabindex 0" do
      html = render_component(&FilterTabs.filter_tabs/1, %{active: :open})

      assert html =~
               ~s(id="filter-tab-open" type="button" role="tab" aria-selected="true" tabindex="0")

      assert html =~
               ~s(id="filter-tab-answered" type="button" role="tab" aria-selected="false" tabindex="-1")
    end

    test "the answered tab is active when selected" do
      html = render_component(&FilterTabs.filter_tabs/1, %{active: :answered})

      assert html =~
               ~s(id="filter-tab-answered" type="button" role="tab" aria-selected="true" tabindex="0")
    end
  end

  describe "RequestCard" do
    @base %{
      index: 1,
      title: "Deploy release 1.4 to prod",
      agent: "claude-code/gsd",
      type: :ask,
      state: :pending
    }

    test "omits the risk badge when both risk fields are absent" do
      html = render_component(&RequestCard.request_card/1, @base)
      refute html =~ "risk:"
    end

    test "shows a real risk sigil and spelled form when risk is stated" do
      html =
        render_component(
          &RequestCard.request_card/1,
          Map.merge(@base, %{risk_level: :high, reversible: "false"})
        )

      assert html =~ "[!!!]"
      assert html =~ "risk:high 3/3 · reversible:false"
    end

    test "omits left/overdue/escalated when nil/false" do
      html = render_component(&RequestCard.request_card/1, @base)
      refute html =~ "overdue"
      refute html =~ "escalated"
      refute html =~ "left:"
    end

    test "renders left/overdue/escalated when present (deferred-field contract, unused in Phase 1)" do
      html =
        render_component(
          &RequestCard.request_card/1,
          Map.merge(@base, %{left: "5m", overdue: true, escalated: true})
        )

      assert html =~ "left:5m"
      assert html =~ "overdue"
      assert html =~ "escalated"
    end

    test "answered row shows the result and who decided" do
      html =
        render_component(
          &RequestCard.request_card/1,
          Map.merge(@base, %{
            state: :answered,
            answered: true,
            result: "ok",
            decided_by: "owner@localhost"
          })
        )

      assert html =~ "result:ok"
      assert html =~ "owner@localhost"
    end

    test "selected row carries aria-selected true" do
      html = render_component(&RequestCard.request_card/1, Map.merge(@base, %{selected: true}))
      assert html =~ ~s(aria-selected="true")
    end

    @tag :backstop
    test "a title far longer than the pane width is never truncated" do
      long_title = String.duplicate("a very long request title that keeps going ", 20)
      html = render_component(&RequestCard.request_card/1, Map.merge(@base, %{title: long_title}))

      assert html =~ long_title
      refute html =~ "truncate"
      refute html =~ "…"
    end
  end

  describe "RiskBadge" do
    test "renders nothing when both level and reversible are absent" do
      html = render_component(&RiskBadge.risk_badge/1, %{})
      assert html == ""
    end

    test "high risk: three glyphs, weight, and the spelled form" do
      html = render_component(&RiskBadge.risk_badge/1, %{level: :high, reversible: "false"})
      assert html =~ "[!!!]"
      assert html =~ "risk:high 3/3 · reversible:false"
    end

    test "medium risk: two glyphs" do
      html = render_component(&RiskBadge.risk_badge/1, %{level: :medium, reversible: "manual"})
      assert html =~ "[!!·]"
      assert html =~ "risk:medium 2/3 · reversible:manual"
    end

    test "low risk: one glyph — never rendered for the absent case" do
      html = render_component(&RiskBadge.risk_badge/1, %{level: :low, reversible: "true"})
      assert html =~ "[!··]"
      assert html =~ "risk:low 1/3 · reversible:true"
    end

    test "risk present without a stated reversible omits that segment" do
      html = render_component(&RiskBadge.risk_badge/1, %{level: :high})
      assert html =~ "risk:high 3/3"
      refute html =~ "reversible:"
    end

    test "block layout for the detail pane" do
      html = render_component(&RiskBadge.risk_badge/1, %{level: :high, layout: :block})
      assert html =~ "flex"
    end
  end

  describe "AgentBadge" do
    test "unverified: spelled in words, name faint + dotted, marker in strongest ink" do
      html = render_component(&AgentBadge.agent_badge/1, %{name: "claude-code/gsd"})

      assert html =~ "[unverified]"
      assert html =~ "text-text-faint"
      assert html =~ "underline decoration-dotted"
      assert html =~ "text-text-primary"
      refute html =~ "accent-actionable"
    end

    test "verified (untested in the running Phase 1 product, exercised only here)" do
      html = render_component(&AgentBadge.agent_badge/1, %{name: "ci-bot", verified: true})

      assert html =~ "[verified]"
      refute html =~ "[unverified]"
      refute html =~ "accent-actionable"
    end
  end

  describe "ActorIdentity" do
    test "unverified actor renders the same treatment as AgentBadge" do
      html = render_component(&ActorIdentity.actor_identity/1, %{name: "owner@localhost"})

      assert html =~ "[unverified]"
      assert html =~ "by"
      refute html =~ "accent-actionable"
    end

    test "method is shown only when verified" do
      unverified =
        render_component(&ActorIdentity.actor_identity/1, %{name: "owner@localhost", method: :sso})

      refute unverified =~ "sso"

      verified =
        render_component(&ActorIdentity.actor_identity/1, %{
          name: "owner@localhost",
          verified: true,
          method: :sso
        })

      assert verified =~ "sso"
    end

    test "renders :service_token without raising (D-04, 02-02-PLAN.md Task 2)" do
      html =
        render_component(&ActorIdentity.actor_identity/1, %{
          name: "agent-service-token-1.access",
          verified: true,
          method: :service_token
        })

      assert html =~ "service_token"
      assert html =~ "[verified"
    end
  end

  describe "MetaList" do
    test "omits a key with no value rather than rendering an empty row" do
      html =
        render_component(&MetaList.meta_list/1, %{
          items: [
            %{key: "state", value: "pending", tone: :default},
            %{key: "source", value: nil, tone: :default}
          ]
        })

      assert html =~ "state"
      refute html =~ "source"
    end

    test "accent tone" do
      html =
        render_component(&MetaList.meta_list/1, %{
          items: [%{key: "type", value: "approve", tone: :accent}]
        })

      assert html =~ "accent-actionable"
    end

    test "quiet tone" do
      html =
        render_component(&MetaList.meta_list/1, %{
          items: [%{key: "external_correlation", value: "abc-123", tone: :quiet}]
        })

      assert html =~ "text-text-secondary"
    end
  end

  describe "ContextBlock" do
    test "renders aligned rows for a flat key/value shape" do
      html =
        render_component(&ContextBlock.context_block/1, %{
          rows: [{"branch", "main"}, {"sha", "abc123"}]
        })

      assert html =~ "branch"
      assert html =~ "abc123"
    end

    test "renders pre-formatted text as-is" do
      html = render_component(&ContextBlock.context_block/1, %{text: "line one\nline two"})
      assert html =~ "line one"
      assert html =~ "<pre"
    end

    test "renders nothing when neither rows nor text is present" do
      html = render_component(&ContextBlock.context_block/1, %{})
      assert html == ""
    end

    test "never applies a raw-HTML helper to agent-supplied content" do
      html =
        render_component(&ContextBlock.context_block/1, %{
          text: "<script>alert(1)</script>"
        })

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    @tag :backstop
    test "wide pre-formatted content scrolls horizontally rather than re-flowing or clipping" do
      wide = String.duplicate("0123456789", 40)
      html = render_component(&ContextBlock.context_block/1, %{text: wide})

      assert html =~ wide
      assert html =~ "overflow-x-auto"
      assert html =~ "whitespace-pre font-mono"
      refute html =~ "whitespace-pre-wrap"
      refute html =~ "truncate"
    end
  end

  describe "RequestTimeline" do
    test "renders each event as a timestamp plus one sentence" do
      html =
        render_component(&RequestTimeline.request_timeline/1, %{
          events: [
            %{
              time: ~U[2026-09-02 21:00:00Z],
              text: "claude-code/gsd created this request.",
              current: false
            },
            %{time: ~U[2026-09-02 21:05:00Z], text: "owner@localhost answered it.", current: true}
          ]
        })

      assert html =~ "claude-code/gsd created this request."
      assert html =~ "owner@localhost answered it."
      assert html =~ "(current)"
      assert html =~ "accent-actionable"
    end

    test "renders nothing extra when no event is current" do
      html =
        render_component(&RequestTimeline.request_timeline/1, %{
          events: [%{time: ~U[2026-09-02 21:00:00Z], text: "created.", current: false}]
        })

      refute html =~ "(current)"
    end
  end

  describe "ChoiceCard (02.1-05-PLAN.md Task 2, CORE-04)" do
    test "renders every option's label and description, and an advisory marker only where sent" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-1",
          state: :editing,
          options: [
            %{id: "a", label: "Option A", description: "First path", recommended: nil},
            %{id: "b", label: "Option B", description: nil, recommended: true}
          ]
        })

      assert html =~ "Option A"
      assert html =~ "First path"
      assert html =~ "Option B"
      assert html =~ "suggested"
    end

    test "on first render no option carries a checked attribute — including the recommended one",
         %{} do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-2",
          state: :editing,
          options: [
            %{id: "a", label: "Option A", description: nil, recommended: nil},
            %{id: "b", label: "Option B", description: nil, recommended: true}
          ]
        })

      # Asserted against the rendered markup — the hazard is a template that
      # emits `checked` derived from `recommended` regardless of what the
      # `selected_option_id` assign says.
      refute html =~ "checked"
    end

    test "an option label containing markup renders escaped, as text" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-3",
          state: :editing,
          options: [
            %{id: "a", label: "<script>alert(1)</script>", description: nil, recommended: nil}
          ]
        })

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a long option label wraps — no truncation, ellipsis, clamp or non-wrapping class anywhere" do
      long_label = String.duplicate("a very long option label word ", 20)

      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-4",
          state: :editing,
          options: [%{id: "a", label: long_label, description: nil, recommended: nil}]
        })

      assert html =~ long_label
      refute html =~ "truncate"
      refute html =~ "text-ellipsis"
      refute html =~ "whitespace-nowrap"
      refute html =~ "line-clamp"
    end

    test "the submit control is disabled until a selection exists, and nothing submits on change" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-5",
          state: :editing,
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}]
        })

      assert html =~ "disabled"
      refute html =~ "phx-submit"
    end

    test "the free-text field appears only when allow_free_text is true" do
      with_flag =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-6",
          state: :editing,
          allow_free_text: true,
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}]
        })

      without_flag =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-7",
          state: :editing,
          allow_free_text: false,
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}]
        })

      assert with_flag =~ "Or write your own answer"
      refute without_flag =~ "Or write your own answer"
    end

    test "with an option selected, the submit control is enabled" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-8",
          state: :editing,
          selected_option_id: "a",
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}]
        })

      refute html =~ "disabled"
    end

    test "the decided state names the chosen option's label, who decided and when" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-9",
          state: :decided,
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}],
          selected_option_ids: ["a"],
          decided_by: %{"label" => "owner@localhost"},
          decided_at: ~U[2026-09-04 12:00:00Z]
        })

      assert html =~ "Option A"
      assert html =~ "owner@localhost"
    end

    test "the decided state names free text when that is what was given" do
      html =
        render_component(&ChoiceCard.choice_card/1, %{
          id: "choice-10",
          state: :decided,
          options: [%{id: "a", label: "Option A", description: nil, recommended: nil}],
          selected_option_ids: [],
          free_text: "Neither of these — do this instead.",
          decided_by: %{"label" => "owner@localhost"},
          decided_at: ~U[2026-09-04 12:00:00Z]
        })

      assert html =~ "Neither of these — do this instead."
    end
  end
end
