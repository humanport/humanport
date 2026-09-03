defmodule Humanport.Actors.CloudflareAccessToken do
  @moduledoc """
  OPS-03 — the claim contract for a Cloudflare Access JWT (D-02, D-03,
  D-05). `use Joken.Config` with `token_config/0` overridden so the issuer
  and the AUD tag are read through `Application.get_env/2` INSIDE
  `token_config/0`, which runs fresh on every `verify_and_validate/1` call —
  never baked in at compile time via `default_claims(iss: ..., aud: ...)`.
  The AUD tag is a value the owner copies out of the Cloudflare dashboard at
  deploy time; a build that would need recompiling to change it is a build
  that cannot be deployed.

  D-05 — `aud` arrives from Cloudflare as a LIST of tags (an Access
  application's audience claim is an array, not a bare string). A validator
  written against a bare string silently refuses every genuine token; one
  that compares the list for equality refuses them just as silently. This
  checks list MEMBERSHIP of the configured tag and refuses anything that
  isn't shaped as a list at all — a token whose `aud` doesn't look like
  Cloudflare's own JWTs are shaped is refused, not coerced.

  The issuer is derived from the SAME team-domain config key the JWKS URL
  is derived from (`Humanport.Actors.CloudflareAccessJwksStrategy`) — one
  value, so the two can never drift apart.

  No default signer is ever configured for this module (no
  `config :joken, ...` anywhere in this codebase, and `default_signer:` is
  never passed to `use Joken.Config`) — `joken_jwks`'s own documentation is
  explicit that a default signer takes precedence over its key-set lookup
  and would silently defeat JWKS-based verification. The proof this holds
  is the happy-path test itself: a default signer would make a token signed
  with the key set's own key fail to verify.

  The `@strategy` module is resolved via `Application.compile_env/3` (a
  compile-time seam, unlike the runtime team-domain/AUD-tag values above —
  `add_hook/2` is a macro that embeds its `strategy:` option into `@hooks`
  at compile time, so there is no runtime hook-selection to lean on) so
  `config/test.exs` can point it at a local stub implementing
  `JokenJwks.SignerMatchStrategy` directly, with no network reachable — see
  `Humanport.CloudflareAccessFixtures.StubJwksStrategy`.
  """

  use Joken.Config

  @strategy Application.compile_env(
              :humanport,
              :cf_access_jwks_strategy,
              Humanport.Actors.CloudflareAccessJwksStrategy
            )

  add_hook(JokenJwks, strategy: @strategy)

  @impl true
  def token_config do
    team_domain =
      Application.get_env(:humanport, :cf_access_team_domain) ||
        raise "HUMANPORT_CF_ACCESS_TEAM_DOMAIN is not configured — " <>
                "#{inspect(__MODULE__)} must not be asked to verify a token without it."

    aud_tag =
      Application.get_env(:humanport, :cf_access_aud) ||
        raise "HUMANPORT_CF_ACCESS_AUD is not configured — " <>
                "#{inspect(__MODULE__)} must not be asked to verify a token without it."

    issuer = issuer(team_domain)

    default_claims(skip: [:iss, :aud])
    |> add_claim("iss", nil, &(&1 == issuer))
    |> add_claim("aud", nil, &aud_contains?(&1, aud_tag))
  end

  @doc "The issuer origin derived from the team domain — shared with the JWKS strategy (D-13)."
  def issuer(team_domain), do: "https://#{team_domain}.cloudflareaccess.com"

  defp aud_contains?(aud, aud_tag) when is_list(aud), do: aud_tag in aud
  defp aud_contains?(_aud, _aud_tag), do: false
end
