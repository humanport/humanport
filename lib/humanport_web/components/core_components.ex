defmodule HumanportWeb.CoreComponents do
  @moduledoc """
  Framework-level UI plumbing that is not part of the HumanPort design system.

  Per the usage rules in `.planning/design/DESIGN-SYSTEM.md` (private repo) and
  AGENTS.md: prefer a `HumanPort.UI.*` component first, a Petal Components v4
  primitive second. What is left here is infrastructure the generator produced
  that Phoenix/LiveView itself relies on (the flash banner and its JS
  helpers) plus gettext error translation used by future Ash/AshPhoenix forms.
  The generator's second-design-system-styled `button/1`, `input/1`, `icon/1`,
  `table/1`, `list/1` and `header/1` helpers were removed: `<.button>` and
  `<.field>` now come from Petal, `<.icon>` from `PetalComponents.Icon`, and
  the rest were unused scaffolding that existed only to demonstrate the
  removed theme plugin.
  """
  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  import PetalComponents.Icon, only: [icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "flex w-80 items-start gap-3 rounded-inner border bg-surface-raised p-3 font-mono text-[13px] text-text-primary shadow-lg sm:w-96",
        @kind == :info && "border-border-hairline",
        @kind == :error && "border-border-destructive"
      ]}
      {@rest}
    >
      <.icon
        :if={@kind == :info}
        name="hero-information-circle"
        class="size-5 shrink-0 text-text-secondary"
      />
      <.icon
        :if={@kind == :error}
        name="hero-exclamation-circle"
        class="size-5 shrink-0 text-accent-destructive"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-bold">{@title}</p>
        <p>{msg}</p>
      </div>
      <button
        type="button"
        class="shrink-0 cursor-pointer text-text-faint hover:text-text-primary"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(HumanportWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(HumanportWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
