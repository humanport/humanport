defmodule Humanport.AgentsTest do
  @moduledoc """
  SEC-04/05 — agent keys: issuing returns a token exactly once and stores
  only its digest, `authenticate/1` accepts exactly the issued token, a
  revoked key is refused, and every issue/revoke writes its own audit event
  (with no request attached) in the same transaction.
  """

  use Humanport.DataCase, async: true

  alias Humanport.Actors.Actor
  alias Humanport.Agents

  @cli %Actor{id: nil, type: :system, label: "release-cli", verified?: false, method: nil}

  defp audit_rows(key_id) do
    key_id_bin = Ecto.UUID.dump!(key_id)

    Repo.all(
      from(e in "audit_events",
        where: e.resource_id == ^key_id_bin,
        select: %{
          event_type: e.event_type,
          resource_type: e.resource_type,
          request_id: e.request_id,
          previous_state: e.previous_state,
          new_state: e.new_state,
          actor_type: e.actor_type,
          metadata: e.metadata
        },
        order_by: e.occurred_at
      )
    )
  end

  describe "issue_key/2" do
    test "returns the token once and stores only its digest" do
      assert {:ok, key, "hp_" <> _ = token} = Agents.issue_key("ci-bot", @cli)

      assert key.label == "ci-bot"
      assert is_nil(key.revoked_at)
      assert String.starts_with?(token, "hp_#{key.prefix}_")
      assert key.secret_hash == Agents.hash_token(token)
      refute key.secret_hash =~ token

      {:ok, reloaded} = Agents.get_agent_key(key.id)
      assert is_nil(Ash.Resource.get_metadata(reloaded, :token))
    end

    test "writes one agent_key.issued audit event that names the key, not the token" do
      {:ok, key, token} = Agents.issue_key("ci-bot", @cli)

      assert [event] = audit_rows(key.id)
      assert event.event_type == "agent_key.issued"
      assert event.resource_type == "agent_key"
      assert is_nil(event.request_id)
      assert event.new_state == "active"
      assert event.actor_type == "system"
      assert event.metadata["label"] == "ci-bot"
      refute inspect(event.metadata) =~ token
    end

    test "refuses a blank label and writes nothing" do
      assert {:error, _} = Agents.issue_key("   ", @cli)
      assert {:ok, []} = Agents.list_agent_keys()
    end
  end

  describe "authenticate/1" do
    test "accepts the issued token and yields a verified agent actor" do
      {:ok, key, token} = Agents.issue_key("ci-bot", @cli)

      assert {:ok, authenticated} = Agents.authenticate(token)
      assert authenticated.id == key.id

      assert %Actor{type: :agent, verified?: true, method: :api_key, label: "ci-bot"} =
               Agents.actor_for(authenticated)
    end

    test "refuses a wrong secret under a real prefix" do
      {:ok, key, _token} = Agents.issue_key("ci-bot", @cli)

      assert {:error, :wrong_secret} = Agents.authenticate("hp_#{key.prefix}_not-the-secret")
    end

    test "refuses an unknown prefix and malformed tokens" do
      assert {:error, :unknown_key} = Agents.authenticate("hp_000000000000_whatever")
      assert {:error, :malformed} = Agents.authenticate("not-a-key")
      assert {:error, :malformed} = Agents.authenticate("hp__secret")
      assert {:error, :malformed} = Agents.authenticate("")
    end
  end

  describe "revoke_key/2" do
    test "revokes the key, refuses it afterwards, and audits the revocation" do
      {:ok, key, token} = Agents.issue_key("ci-bot", @cli)

      assert {:ok, revoked} = Agents.revoke_key(key, @cli)
      refute is_nil(revoked.revoked_at)
      assert {:error, :revoked} = Agents.authenticate(token)

      assert [_issued, event] = audit_rows(key.id)
      assert event.event_type == "agent_key.revoked"
      assert event.previous_state == "active"
      assert event.new_state == "revoked"
    end

    test "a second revoke is refused and writes no second event" do
      {:ok, key, _token} = Agents.issue_key("ci-bot", @cli)
      {:ok, _revoked} = Agents.revoke_key(key, @cli)

      assert {:error, _} = Agents.revoke_key(key, @cli)
      assert length(audit_rows(key.id)) == 2
    end
  end
end
