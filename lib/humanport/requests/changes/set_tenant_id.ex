defmodule Humanport.Requests.Changes.SetTenantId do
  @moduledoc """
  Sets `tenant_id` from application config (`:humanport, :default_tenant_id`),
  never from the wire (D-05). Phase 1 has no tenancy logic behind this value —
  it exists purely so every query, index and policy Phase 4 needs is already
  scoped by tenant, rather than being retrofitted onto rows that predate it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :tenant_id, default_tenant_id())
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:atomic, %{tenant_id: default_tenant_id()}}
  end

  defp default_tenant_id do
    Application.fetch_env!(:humanport, :default_tenant_id)
  end
end
