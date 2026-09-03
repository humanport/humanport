defmodule Humanport.CloudflareAccessFixtures.StubJwksStrategy do
  @moduledoc """
  Wave 0 test seam (02-VALIDATION.md) — implements
  `JokenJwks.SignerMatchStrategy` directly, with no GenServer, no ETS cache
  and no network call, so `Humanport.Actors.CloudflareAccessToken` can be
  exercised end to end in a test run. Configured as
  `:humanport, :cf_access_jwks_strategy` in `config/test.exs`, read by
  `CloudflareAccessToken` via `Application.compile_env/3` — this mirrors
  the `:actor_resolver` seam the project already has: one config key, one
  swap, no mocking library.

  Returns the SAME signer `Humanport.CloudflareAccessFixtures.signed_token/1`
  used to sign a fixture token, for the fixture's own known `kid` — every
  other `kid` is refused exactly the way an unrecognised production key
  would be, which is what the "signed by a key the signer source does not
  hold" test case exercises.
  """

  @behaviour JokenJwks.SignerMatchStrategy

  alias Humanport.CloudflareAccessFixtures

  @impl true
  def match_signer_for_kid(kid, _hook_options) do
    if kid == CloudflareAccessFixtures.kid() do
      {:ok, CloudflareAccessFixtures.signer()}
    else
      {:error, :kid_does_not_match}
    end
  end
end

defmodule Humanport.CloudflareAccessFixtures do
  @moduledoc """
  OPS-03 test fixtures — a locally generated RSA keypair and a builder for
  Cloudflare-Access-shaped JWTs, so `Humanport.Actors.CloudflareAccessToken`
  and `Humanport.Actors.Resolvers.CloudflareAccess` are testable with no
  network call reaching Cloudflare (02-VALIDATION.md Wave 0 Requirements).

  `team_domain/0` and `aud_tag/0` MUST match the
  `:cf_access_team_domain`/`:cf_access_aud` values configured in
  `config/test.exs` — `CloudflareAccessToken.token_config/0` reads those
  via `Application.get_env/2`, so the values a test signs a token against
  and the values the token module validates against have to agree by
  construction, not by coincidence.

  The RSA key is generated ONCE, at this module's own compile time (a
  module attribute, evaluated once during `mix compile`/`mix test`) — the
  same value is returned by every call to `signer/0`, in this module and in
  `StubJwksStrategy`, for the lifetime of one compiled test run.
  """

  alias Joken.Signer

  @kid "test-fixture-kid-1"
  @team_domain "test-team"
  @aud_tag "test-aud-tag"
  @signer Signer.create("RS256", JOSE.JWK.generate_key({:rsa, 2048}), %{"kid" => @kid})

  def kid, do: @kid
  def team_domain, do: @team_domain
  def aud_tag, do: @aud_tag
  def signer, do: @signer

  @doc "The full issuer origin a genuine token from this fixture's team domain carries."
  def issuer, do: Humanport.Actors.CloudflareAccessToken.issuer(@team_domain)

  @doc """
  Builds and signs a Cloudflare-Access-shaped JWT with this fixture's own
  key. Every claim is overridable via `opts` so a test can construct
  exactly the malformed shape it needs (wrong issuer, wrong audience,
  expired, signed with a DIFFERENT key entirely via `:signer`, or a
  different `:kid` header so the stub strategy refuses to match it).

  Defaults to a genuine, correctly-scoped, unexpired human (`email`) token.
  """
  def signed_token(opts \\ []) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => Keyword.get(opts, :iss, issuer()),
        "aud" => Keyword.get(opts, :aud, [@aud_tag]),
        "exp" => Keyword.get(opts, :exp, now + 3600),
        "iat" => now,
        "sub" => Keyword.get(opts, :sub, "test-sub-1"),
        "email" => Keyword.get(opts, :email, "owner@example.com")
      }
      |> maybe_put("common_name", Keyword.get(opts, :common_name))
      |> drop_keys(Keyword.get(opts, :without, []))

    signer = Keyword.get(opts, :signer, @signer)

    {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)
    token
  end

  @doc "A signer built from a DIFFERENT keypair than `signer/0` — for the wrong-key test case."
  def other_signer do
    Signer.create("RS256", JOSE.JWK.generate_key({:rsa, 2048}), %{"kid" => @kid})
  end

  defp maybe_put(claims, _key, nil), do: claims
  defp maybe_put(claims, key, value), do: Map.put(claims, key, value)

  defp drop_keys(claims, keys), do: Map.drop(claims, Enum.map(keys, &to_string/1))
end
