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

  D-13 — for a plain HTTP request (`resolve/1` on a `%Plug.Conn{}`), the
  token arrives as the `Cf-Access-Jwt-Assertion` request header (checked
  first — `Plug.Conn.get_req_header/2` matches the header name
  case-insensitively) or the `CF_Authorization` cookie (checked second —
  the cookie name is exactly as Cloudflare sets it, case-sensitive).

  02-02-PLAN.md Task 1 — a LiveView socket (`resolve/1` on a
  `%Phoenix.LiveView.Socket{}`) is a DIFFERENT case, not a variant of the
  same extraction: Phoenix does not expose the `CF_Authorization` cookie
  (or any raw cookie) to a socket's `connect_info` at all — `:cookies` is
  not a valid `connect_info` key in the installed Phoenix/LiveView version,
  confirmed by reading `Phoenix.Socket.Transport.load_config/1` and the
  endpoint moduledoc's own "you can't access cookies and other headers in
  your socket" note (a deliberate cross-site-WebSocket-hijack defense).
  `Phoenix.LiveView.get_connect_info/2` does not support `:session` either
  (confirmed by reading its `conn_connect_info/2` clauses) — the session
  reaches a mount as `on_mount/4`'s own THIRD ARGUMENT instead, which
  `HumanportWeb.Plugs.ResolveActor.on_mount/4` stashes into
  `socket.private[:hp_session]` before calling this resolver (see that
  module's moduledoc). This clause reads the resolved-actor SNAPSHOT
  `ResolveActor.call/2` writes into that same Plug session on every
  successful dead-render resolve (`@actor_session_key` below, kept in sync
  with that module's own literal). Trusting the snapshot is not weaker than
  re-verifying a raw JWT would have been: Cloudflare Access re-checks at
  the EDGE on every request, including a websocket reconnect, before it
  ever reaches this application (D-03's own framing — the application is
  the *second* line of defence) — trusting a snapshot this server itself
  wrote, signed by its own `SECRET_KEY_BASE`, moments earlier, is sound.

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

  D-01 — a service-token JWT carries `common_name` (the service token's own
  Client ID) instead of `email`; that is Cloudflare's OWN distinction, not
  ours, checked here purely by which key is present on the VERIFIED claims
  map — never by a caller-supplied "I am a service" flag, a header, or a
  body field. `common_name` is checked first (`actor_from_claims/1`'s
  clause order below), so a token carrying both keys resolves as a
  service actor; nothing in this codebase produces such a token, but the
  order is deliberate rather than incidental. A correctly-signed,
  correctly-scoped token that carries neither `common_name` nor `email` is
  refused (`:invalid_token`), never resolved to some default actor.
  """

  @behaviour Humanport.Actors.Resolver

  alias Humanport.Actors.Actor
  alias Humanport.Actors.CloudflareAccessToken

  @header "cf-access-jwt-assertion"
  @cookie "CF_Authorization"

  # Cross-referenced with `HumanportWeb.Plugs.ResolveActor`'s own
  # `@actor_session_key` literal — see both moduledocs. Not shared as a
  # function call to avoid a `lib/humanport` -> `lib/humanport_web` ->
  # `lib/humanport` layering loop between the two.
  @actor_session_key "hp_resolved_actor"

  @impl true
  def resolve(%Plug.Conn{} = conn) do
    conn
    |> extract_from_conn()
    |> verify_and_map()
  end

  def resolve(%Phoenix.LiveView.Socket{private: private}) do
    private
    |> Map.get(:hp_session, %{})
    |> resolve_from_session()
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

  # `session` is `nil` when the socket's `connect_info` carries no session
  # at all (declared without `session: ...`, or a request with no cookie
  # attached) — never crash on that, refuse it like any other missing
  # credential.
  defp resolve_from_session(%{} = session) do
    case Map.get(session, @actor_session_key) do
      %{"verified" => true} = snapshot -> {:ok, actor_from_snapshot(snapshot)}
      _ -> {:error, :missing_token}
    end
  end

  defp resolve_from_session(_session), do: {:error, :missing_token}

  defp actor_from_snapshot(snapshot) do
    %Actor{
      id: snapshot["id"],
      type: String.to_existing_atom(snapshot["type"]),
      label: snapshot["label"],
      verified?: true,
      method: snapshot["method"] && String.to_existing_atom(snapshot["method"])
    }
  end

  defp ensure_scoped_correctly(%{"iss" => _, "aud" => _}), do: :ok
  defp ensure_scoped_correctly(_claims), do: {:error, :invalid_token}

  # D-01 — the service-token clause. Checked FIRST: a service token's
  # "common_name" is its own Client ID, never a client-supplied flag. Order
  # matters only in the sense that it is deliberate, not because the two
  # clauses could otherwise collide — a genuine Cloudflare Access token
  # carries exactly one of "common_name" or "email", never neither and (per
  # Cloudflare's own token shapes) never a reason to prefer one over the
  # other if it somehow carried both.
  defp actor_from_claims(%{"common_name" => client_id} = claims) do
    {:ok,
     %Actor{
       id: claims["sub"],
       type: :service,
       label: client_id,
       verified?: true,
       method: :service_token
     }}
  end

  # Cloudflare's OWN distinction, not ours: a service-token JWT carries
  # "common_name" instead of "email" (clause above).
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
