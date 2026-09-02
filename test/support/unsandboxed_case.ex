defmodule Humanport.UnsandboxedCase do
  @moduledoc """
  A case template for tests that must run OUTSIDE the Ecto SQL sandbox.

  Under `Ecto.Adapters.SQL.Sandbox` in ownership or shared mode, collaborating
  processes share a single connection and therefore a single transaction — two
  concurrent writes on that one connection serialise trivially, so a
  conflict-resolution test written against the ordinary sandboxed case
  (`Humanport.DataCase`) passes whether or not the guarantee it claims to
  prove (CORE-07 — first valid terminal response wins, enforced at the
  database level) is actually present. This case template puts the repo in
  `:auto` mode for the duration of the test instead, so concurrent test
  processes get real, separate connections and a genuine race.

  Tests using this case:

    - run `async: false` — ExUnit's own default when no `async:` option is
      passed to `use`, which this module relies on rather than re-asserting
    - must clean up every row they create, in `on_exit` — nothing rolls back
      automatically once the sandbox is bypassed

  Plan 01-03 is the first consumer: the CORE-07 concurrent-answer test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Humanport.Repo

      import Ecto.Query
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Humanport.Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Humanport.Repo, :manual)
    end)

    :ok
  end
end
