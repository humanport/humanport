defmodule Humanport.Agents do
  @moduledoc """
  `Ash.Domain` for agent credentials (SEC-04/05) — the only sanctioned
  writer of `Humanport.Agents.AgentKey`. `issue_key/2` and `revoke_key/2`
  each open ONE `Ash.transaction/3` spanning the change and its audit event,
  exactly like `Humanport.Requests`.

  `authenticate/1` turns a presented bearer token into its key, and
  `actor_for/1` turns that key into the verified `%Actor{}` every write path
  downstream receives — `HumanportWeb.Plugs.AuthenticateAgent` is the only
  caller of either on a request.
  """

  use Ash.Domain

  alias Humanport.Actors.Actor
  alias Humanport.Agents.AgentKey

  resources do
    resource AgentKey do
      define :list_agent_keys, action: :read
      define :get_agent_key, action: :read, get_by: [:id]
    end
  end

  @doc """
  Issues a new key labelled `label` and writes the `agent_key.issued` audit
  event in one transaction. Returns `{:ok, key, token}` — `token` is the
  only copy of the plaintext that will ever exist.
  """
  @spec issue_key(String.t(), Actor.t()) ::
          {:ok, Ash.Resource.record(), String.t()} | {:error, term()}
  def issue_key(label, %Actor{} = actor) do
    result =
      Ash.transaction([AgentKey, Humanport.Audit.Event], fn ->
        with {:ok, key} <-
               AgentKey
               |> Ash.Changeset.for_create(:issue, %{label: label}, actor: actor)
               |> Ash.create(),
             {:ok, _event} <- record_event("agent_key.issued", key, nil, "active", actor) do
          key
        else
          {:error, error} -> Ash.DataLayer.rollback(AgentKey, error)
        end
      end)

    with {:ok, key} <- result do
      {:ok, key, Ash.Resource.get_metadata(key, :token)}
    end
  end

  @doc """
  Revokes `key` and writes the `agent_key.revoked` audit event in one
  transaction. A key that is already revoked is refused rather than
  re-stamped.
  """
  @spec revoke_key(Ash.Resource.record(), Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def revoke_key(%AgentKey{} = key, %Actor{} = actor) do
    Ash.transaction([AgentKey, Humanport.Audit.Event], fn ->
      with {:ok, revoked} <-
             key
             |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
             |> Ash.update(),
           {:ok, _event} <- record_event("agent_key.revoked", revoked, "active", "revoked", actor) do
        revoked
      else
        {:error, error} -> Ash.DataLayer.rollback(AgentKey, error)
      end
    end)
  end

  @doc """
  Resolves a presented token to its active key. Every failure — malformed,
  unknown prefix, wrong secret, revoked — is `{:error, reason}`; the reason
  is for the server log only, and callers must not tell the client which
  one it was.
  """
  @spec authenticate(String.t()) :: {:ok, Ash.Resource.record()} | {:error, atom()}
  def authenticate(token) when is_binary(token) do
    with {:ok, prefix} <- parse_prefix(token),
         {:ok, key} <- fetch_by_prefix(prefix),
         :ok <- verify_secret(key, token) do
      if is_nil(key.revoked_at), do: {:ok, key}, else: {:error, :revoked}
    end
  end

  @doc "The verified actor an authenticated key acts as."
  @spec actor_for(Ash.Resource.record()) :: Actor.t()
  def actor_for(%AgentKey{} = key) do
    %Actor{id: key.id, type: :agent, label: key.label, verified?: true, method: :api_key}
  end

  @doc false
  def hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp parse_prefix(token) do
    case String.split(token, "_", parts: 3) do
      ["hp", prefix, secret] when prefix != "" and secret != "" -> {:ok, prefix}
      _ -> {:error, :malformed}
    end
  end

  defp fetch_by_prefix(prefix) do
    case AgentKey |> Ash.Query.for_read(:by_prefix, %{prefix: prefix}) |> Ash.read_one() do
      {:ok, %AgentKey{} = key} -> {:ok, key}
      {:ok, nil} -> {:error, :unknown_key}
      {:error, _error} -> {:error, :unknown_key}
    end
  end

  defp verify_secret(key, token) do
    if Plug.Crypto.secure_compare(hash_token(token), key.secret_hash),
      do: :ok,
      else: {:error, :wrong_secret}
  end

  # A key event belongs to no request: `request_id` is nil and the key is the
  # event's resource. The metadata names the key, never the token.
  defp record_event(event_type, key, previous_state, new_state, actor) do
    Humanport.Audit.record(event_type, %{
      tenant_id: key.tenant_id,
      request_id: nil,
      resource_type: "agent_key",
      resource_id: key.id,
      previous_state: previous_state,
      new_state: new_state,
      actor: actor,
      metadata: %{label: key.label, prefix: key.prefix}
    })
  end
end
