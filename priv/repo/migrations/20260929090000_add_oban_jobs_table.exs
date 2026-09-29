defmodule Humanport.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  ROUTE-* — Oban's own tables (`oban_jobs`, `oban_peers`), created by Oban's
  versioned migrations rather than by hand. Not an Ash resource, so
  `mix ash.codegen` does not generate or track it.
  """

  use Ecto.Migration

  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down(version: 1)
end
