defmodule Humanport.Actors.Resolvers.CloudflareAccess do
  @moduledoc """
  D-11 — the Phase 2 implementation of the D-09 actor-resolver seam
  (`Humanport.Actors.Resolver`), swapped in via
  `config :humanport, :actor_resolver` from `config/runtime.exs`, gated on
  `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` — never in `compose.yaml` (02-RESEARCH.md
  Pitfall 5; `config/config.exs`'s compile-time default stays `Env`).

  D-02 — every rejection returns `{:error, atom}`, never a raised exception
  and never a fallback actor. It is `HumanportWeb.Plugs.ResolveActor` that
  turns that into an HTTP 401 or a terminated LiveView mount (the WR-05
  fix); this module never renders a response and never redirects.

  D-13 — the token arrives as the `Cf-Access-Jwt-Assertion` request header
  (checked first — `Plug.Conn.get_req_header/2` matches the header name
  case-insensitively) or the `CF_Authorization` cookie (checked second —
  the cookie name is exactly as Cloudflare sets it, case-sensitive).

  D-05 — the `aud` claim is checked, inside
  `Humanport.Actors.CloudflareAccessToken`, against this application's own
  AUD tag — not merely validated as a well-formed token from the shared
  Cloudflare account. Three projects share this account and this host; a
  token minted for a sibling application must be refused here, not merely
  logged. This resolver additionally asserts `iss`/`aud` are actually
  PRESENT on the verified claims (`ensure_scoped_correctly/1`) — Joken's
  own claim-validation only runs for a claim present in the token
  (confirmed by reading `deps/joken/lib/joken.ex`'s `reduce_validations/3`,
  which iterates the token's own claim map, not the configured claim
  list), so a token missing `aud` entirely would otherwise pass
  unchecked. D-05 is named the single most load-bearing check this
  resolver performs; presence is asserted explicitly rather than assumed
  from Cloudflare's documented (but not application-enforced) shape.

  D-04 — a verified result here is recorded in the audit trail
  (`verified?: true`) and used for NOTHING else. This resolver makes no
  authorization decision and never will (SEC-02 is Phase 4).

  The resolver never reads a caller-supplied "I am a service" flag and
  never treats the mere PRESENCE of the header as identity —
  `Humanport.Actors.Resolver`'s own moduledoc warns against exactly that
  trap. `verified?: true` is earned only by a passing
  signature/issuer/audience/expiry check; the header only says "here is a
  token to verify."

  The `common_name` (service-token, D-01) claims branch is Phase 2's
  Plan 02-02 — this tracer proves the human/`email` path end to end first.
  A correctly-signed, correctly-scoped token that carries neither `email`
  nor a recognised claims shape is refused (`:invalid_token`), not
  resolved to a service actor and not left to crash the request.
  """

  @behaviour Humanport.Actors.Resolver

  alias Humanport.Actors.Actor
  alias Humanport.Actors.CloudflareAccessToken

  @header "cf-access-jwt-assertion"
  @cookie "CF_Authorization"

  @impl true
  def resolve(%Plug.Conn{} = conn) do
    conn
    |> extract_from_conn()
    |> verify_and_map()
  end

  def resolve(%Phoenix.LiveView.Socket{} = socket) do
    socket
    |> extract_from_socket()
    |> verify_and_map()
  end

  defp verify_and_map(:error), do: {:error, :missing_token}

  defp verify_and_map({:ok, raw_jwt}) do
    with {:ok, claims} <- CloudflareAccessToken.verify_and_validate(raw_jwt),
         :ok <- ensure_scoped_correctly(claims),
         {:ok, actor} <- actor_from_claims(claims) do
      {:ok, actor}
    else
      {:error, _reason} = error -> normalize_error(error)
    end
  end

  defp extract_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, @header) do
      [token | _] -> {:ok, token}
      [] -> extract_cookie_from_conn(conn)
    end
  end

  defp extract_cookie_from_conn(conn) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.req_cookies[@cookie] do
      nil -> :error
      token -> {:ok, token}
    end
  end

  defp extract_from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :cookies) do
      %{@cookie => raw_jwt} -> {:ok, raw_jwt}
      _ -> :error
    end
  end

  defp ensure_scoped_correctly(%{"iss" => _, "aud" => _}), do: :ok
  defp ensure_scoped_correctly(_claims), do: {:error, :invalid_token}

  # Cloudflare's OWN distinction, not ours: a service-token JWT carries
  # "common_name" instead of "email" — that branch is Plan 02-02's; this
  # tracer implements the human/email path only, and refuses (rather than
  # crashes on) anything else.
  defp actor_from_claims(%{"email" => email} = claims) do
    {:ok,
     %Actor{
       id: claims["sub"],
       type: :human,
       label: email,
       verified?: true,
       method: :sso
     }}
  end

  defp actor_from_claims(_claims), do: {:error, :invalid_token}

  # Normalizes both Joken's own claim-validation failure shape
  # (`{:error, message: _, claim: key, claim_val: _}`, from
  # `deps/joken/lib/joken.ex`'s `reduce_validations/3`) and every other
  # failure (signature mismatch, unknown `kid`, JWKS fetch failure) down to
  # the small atom vocabulary `fallback_controller.ex`'s error style
  # already uses — `:wrong_audience` for D-05's specific case,
  # `:invalid_token` for everything else. Nothing from Joken's internal
  # error shapes leaks past this resolver.
  defp normalize_error({:error, opts}) when is_list(opts) do
    case Keyword.get(opts, :claim) do
      "aud" -> {:error, :wrong_audience}
      _ -> {:error, :invalid_token}
    end
  end

  defp normalize_error({:error, _reason}), do: {:error, :invalid_token}
end
