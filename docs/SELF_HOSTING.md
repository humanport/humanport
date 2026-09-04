# Self-hosting HumanPort

This is everything you need to run this version of HumanPort yourself, without
asking anyone. It is honest about what this version does and does not do —
read the [Limits of this version](#limits-of-this-version) section before you
put it anywhere reachable from the internet.

## Quickstart

```bash
git clone https://github.com/humanport/humanport.git
cd humanport
docker compose up
```

That is the whole thing. No variable has to be exported first. Once the
application container reports it is serving, open <http://localhost:4000/requests>.

To confirm the deployment yourself the same way the project's own release
gate does, run the scripted acceptance check instead of clicking around:

```bash
bin/smoke.sh
```

It builds the image, starts the stack, creates an `ask` and an `approve`
request over plain HTTP, restarts the application container mid-flight and
confirms both requests survive unchanged, confirms a long-poll wait returns
the moment an answer arrives rather than at its timeout, confirms a second
response to an already-decided request is refused as a conflict, confirms an
unimplemented request type (`choose`, `escalate`) is refused rather than
silently accepted, and tears everything down again. It is safe to re-run.

## The only required infrastructure dependency is PostgreSQL

`docker compose up` starts exactly two containers: the HumanPort application
and PostgreSQL. No cache, no message broker, no workflow engine, and no
container orchestrator (Kubernetes or otherwise) is required to run the core
product. `compose.yaml` is the artifact this claim is checked against — if a
service is not in that file, HumanPort does not need it to run.

## The runtime fetches nothing from a third party — the build does

Once it is running, HumanPort serves everything the browser loads from itself:
fonts, icons, stylesheets and scripts are all vendored into the image at build
time. There is no CDN font, no remote stylesheet, no CDN script, no hotlinked
image, and no telemetry beacon anywhere in the running application. Open the
browser's network log against a running instance and you will not see a
request leave for anywhere but the instance itself.

Say the boundary plainly, because it is easy to assume it covers building too
and it does not: **building** the image is not air-gapped. `docker compose
build` needs network access to download the Tailwind CLI and esbuild
standalone binaries, and the icon library is fetched from a version-control
host as a build-time dependency. None of that reaches the running container —
it is consumed entirely inside the build stage and discarded — but a fully
offline build is not something this version supports. If you cannot give the
build step network access, a published OCI image removes this problem for you
entirely (planned; not yet available for this version).

## What the audit trail guarantees, and what it does not

Every security-sensitive state change — a request answered, approved or
rejected — writes a row to an append-only `audit_events` table. That
"append-only" is enforced by a PostgreSQL trigger, not by application
convention: an `UPDATE`, `DELETE` or `TRUNCATE` against that table is rejected
by the database itself, whether it is attempted through the application or by
hand from a database console.

Be precise about where that guarantee ends. A table owner — whoever holds
superuser or table-owner privileges on the underlying PostgreSQL database —
can still `DROP TABLE audit_events` or `ALTER TABLE ... DISABLE TRIGGER`. No
trigger can prevent either. This version deliberately does not run the
database behind a second, more restricted role to close that gap, because
doing so would work against the same one-command startup this guide opens
with. If your threat model includes protecting the audit trail from whoever
already has database-administrator access to your PostgreSQL instance, that is
not a guarantee this version makes.

## Limits of this version

**This build must not be exposed to the internet.** Read that as an
operational warning, not a footnote: there is no authentication, no
authorization, and no tenancy in the application itself. Every request to the
API and the web inbox is served to whoever can reach the port — there is
nothing in front of it deciding whether they should be able to. Putting a
gate in front of the application (so far, a single-user access gate is the
plan) is required before this is reachable from anywhere but a trusted
network, and that gate is not part of this version.

Concretely, in this version:

- No login. No session belongs to a specific person; the acting human is read
  from an environment variable and recorded as unverified.
- No authorization. There is nothing evaluating who is allowed to see or
  answer a request.
- No tenancy boundary that is actually enforced at the access-control layer,
  even though the schema already carries a tenant column for later.

Run it on a machine you trust, on a network you trust, and treat "next to my
other local services" as the threat model this version is built for.

## Environment variables

None of these are required for `docker compose up` on a clean machine. Set the
ones that matter for your situation.

| Variable | Read by | Default | What it does |
|---|---|---|---|
| `SECRET_KEY_BASE` | `rel/overlays/bin/{migrate,server}` | generated at container start if unset | Signs and encrypts the Phoenix session cookie. If unset, a random value is generated **every time the container starts**, with a warning printed to the container logs — any session in progress does not survive a restart. Set this to a fixed, secret value (`mix phx.gen.secret`, or `openssl rand -base64 48`) for anything you intend to keep running. |
| `HUMANPORT_ACTOR_EMAIL` | `Humanport.Actors.Resolvers.Env` | `owner@localhost` | The label recorded as the acting human for every local write, as long as `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` (below) is unset — that is the resolver a bare `docker compose up` always uses. Always recorded (and rendered) as unverified — this version never claims more confidence in an identity than it actually has. |
| `DATABASE_URL` | `config/runtime.exs` | set in `compose.yaml`, pointing at the `db` service | The Ecto connection string (`ecto://USER:PASS@HOST/DATABASE`). Only relevant if you are not using the bundled `db` service — for example, pointing the application at an external PostgreSQL instance. |
| `PHX_HOST` | `config/runtime.exs` | `localhost` (set in `compose.yaml`) | The hostname the application believes it is served from. Affects generated absolute URLs; does not affect what interface it binds to. |
| `PORT` | `config/runtime.exs` | `4000` | The port the application listens on inside the container. `compose.yaml` publishes container port 4000 to host port 4000; change both together if you need a different host port. |
| `HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS` | `config/runtime.exs` | `50` | The ceiling on `GET /api/v1/requests/:id?wait=N` — a request for a longer wait is clamped to this value, never honored raw. 50s sits under Bandit's own 60s connection read timeout with margin; lower it if you put a reverse proxy in front with a shorter timeout of its own. |
| `HUMANPORT_DEFAULT_TENANT_ID` | `config/config.exs` / `config/runtime.exs` | a fixed placeholder UUID | Overrides the single tenant every request in this version is written under. There is no multi-tenancy logic behind this in Phase 1 — the column exists so a later phase does not have to retrofit it. |
| `ECTO_IPV6` | `config/runtime.exs` | unset (IPv4) | Set to `true` or `1` if your database is only reachable over IPv6. |
| `POOL_SIZE` | `config/runtime.exs` | `10` | The Ecto connection pool size. |
| `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` | `config/runtime.exs` | unset or blank — `Resolvers.Env`, `verified? false` | The Cloudflare Access team name (just the name, not a URL — the application derives both the JWKS URL and the expected issuer from this one value, so the two can never disagree). Setting this to a **non-blank** value swaps the actor resolver to `Resolvers.CloudflareAccess` and makes `HUMANPORT_CF_ACCESS_AUD` required. Blank counts as unset, because `compose.yaml` declares this variable as `${VAR:-}` — the only Compose form that reads a value out of `--env-file` — and that renders as an empty string whenever nothing is configured. **Read the paragraph below before setting this.** |
| `HUMANPORT_CF_ACCESS_AUD` | `config/runtime.exs` | required if the team domain is set; unused otherwise | The AUD tag of THIS instance's own Cloudflare Access application, copied from its dashboard. Without it, a token minted for any other Access application in the same Cloudflare account would be accepted — the application refuses to start with a team domain set and no AUD tag, rather than starting half-configured. |
| `HUMANPORT_MCP_ALLOWED_ORIGINS` | `config/runtime.exs` | unset — every browser-originated `/mcp` request is refused | A comma-separated list of `Origin` values allowed to reach `POST /mcp`. Only relevant to a browser-based caller; a non-browser agent runtime never sends an `Origin` header at all, so this never affects it either way. See [The MCP endpoint](#the-mcp-endpoint) below. |
| `HUMANPORT_MCP_AWAIT_TIMEOUT_SECONDS` | `config/runtime.exs` | `50` | The ceiling on the MCP `await` tool's own wait, in seconds — independent of (but defaulting to match) `HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS` above. See [The MCP endpoint](#the-mcp-endpoint) below for what `await` actually does with this. |

### Setting `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` changes what an unauthenticated request gets

This is not a footnote — read it before you export either variable above. With no Cloudflare
configuration (the default), this instance behaves exactly as described in
[Limits of this version](#limits-of-this-version): no login, the acting human read from an
environment variable, everything unverified. The moment `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` is
set, that changes completely: every request — over the API and the web inbox alike — that does
not carry a genuine, current, correctly-scoped Cloudflare Access token is refused with 401.
That is the intended, locked behaviour (fail closed rather than fail open), not a defect — but
it means setting this variable on an instance that is NOT actually sitting behind a configured
Cloudflare Access application in front of it will lock out every request, including your own.
If that happens, the recovery is unsetting `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` (and
`HUMANPORT_CF_ACCESS_AUD`) and restarting — the resolver reverts to `Resolvers.Env` on the next
boot, with nothing else to undo.

The `db` service's own credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`,
`POSTGRES_DB`) are fixed in `compose.yaml` and match `DATABASE_URL`'s default —
change them together if you change either.

## `POST /api/v1/requests/:id/respond` body shapes

The body's shape is decided by the request's own type, not by a field
naming the type explicitly:

- An `ask` request: `{"answer": "<free text>"}`.
- An `approve` request: `{"decision": "approve"}` or `{"decision": "reject"}`.
- A `choose` request (CORE-04): `{"selected_option_ids": ["<id>", ...]}`
  (a list, possibly empty when free text is given instead), and/or
  `{"free_text": "<text>"}` on a request whose `allow_free_text` is `true`.
  A body naming `selected_option_ids` is dispatched ahead of a free-text-only
  body, so a body carrying both goes through the identical
  `Humanport.Requests.choose/3` call with both fields exactly as sent —
  there is one write path here too, the same domain function the `choose`
  MCP tool's own answer path and the web inbox's decision block both call.
  The result renders `selected_option_ids` (a list, even for one selection)
  and `free_text`, alongside `decided_by`/`decided_at` — never the
  approve/reject `decision` field, which a `choose` result never carries.

Sending the wrong shape for the request's own type is `422` (`invalid`),
never `409` — an agent's retry loop needs to be able to tell "this call was
malformed" apart from "someone else already answered."

## The MCP endpoint

`POST /mcp` is the same product as `POST /api/v1/requests` and its two
siblings, reached from an agent runtime instead of a plain HTTP client. A
request created through it is written through the identical
`Humanport.Requests.submit/2` domain function the HTTP controller calls, and
is indistinguishable afterwards in the inbox, in storage, and in the audit
trail from one created over `/api/v1` — there is one write path, not two.

- **One method, one path.** `POST` is the only method this endpoint answers.
  `GET` and `DELETE` both return `405` — this revision of the protocol
  (`2026-07-28`) defines no meaning for either on this endpoint: no
  standalone event stream, no session-delete verb.
- **Required headers.** Every request carries `MCP-Protocol-Version`,
  `Mcp-Method`, and — for a `tools/call` — `Mcp-Name`, each mirroring a value
  already present in the JSON-RPC body. A disagreement between a header and
  the body is refused `400`; this is the transport-level integrity check the
  spec requires, not an authentication mechanism.
- **`server/discover` advertises `2026-07-28` only.** No `initialize`
  handshake exists in this revision, and none is implemented here. A request
  naming a protocol version this instance does not support is refused `400`
  with the versions it does support.
- **No session state.** This revision removed protocol-level MCP sessions
  entirely: this endpoint mints no session id, echoes none back, and ignores
  one if an older client sends it. It is stateless in the same sense the rest
  of this application is — see [Limits of this version](#limits-of-this-version)
  for what that does and does not mean for `PROTO-04`-style multi-node
  retrieval, which this version does not implement.
- **No authentication of its own.** `/mcp` depends on exactly the same
  Cloudflare Access gate `/api/v1` does — see
  [Setting `HUMANPORT_CF_ACCESS_TEAM_DOMAIN`](#setting-humanport_cf_access_team_domain-changes-what-an-unauthenticated-request-gets)
  above. Without it, `/mcp` is exactly as unauthenticated as the rest of this
  version.
- **Five tools so far.** `tools/list` currently returns `ask` (creates a
  free-text request), `approve` (creates an approval request — it asks a
  human to approve or reject; it does NOT itself decide anything), `choose`
  (creates a request asking a human to pick from a set of caller-supplied,
  opaque named options — CORE-04; it does NOT itself decide anything
  either, and the options it is given are stored and returned unchanged,
  never interpreted), `check` (an immediate, non-waiting glance at a
  request's current state) and `await` (see below). `escalate` is later
  work, not yet reachable here.
  - A `choose` call's `options` argument is a list of `{id, label,
    description?, recommended?}` objects. `id` and `label` are required;
    `description` and `recommended` are optional and come back exactly as
    absent when omitted — never defaulted to a value HumanPort invented.
    `recommended` is advice shown beside an option, never a default and
    never a pre-selection: a human who submits without choosing submits
    nothing, regardless of which option (if any) was marked recommended.
  - The human's answer, once made, is always a **list** of chosen option
    ids — even when only one may be chosen (`max_selections`, defaulting to
    `1`) — because a scalar result now would have to become a list later,
    breaking the published contract exactly when the first SDKs exist. When
    `allow_free_text` is `true`, the human may answer with free text
    instead of an option id; the result names which happened by which of
    `selected_option_ids`/`free_text` came back populated.
- **`check` and `await` are the same primitive's two branches.** `check`
  reads and returns immediately, whatever the request's state. `await`
  holds the connection open until the request is answered or its own
  ceiling elapses (`HUMANPORT_MCP_AWAIT_TIMEOUT_SECONDS` above, defaulting
  to match `HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS`). Both render the
  identical result shape — the created/read request's own wire
  representation, plus a small `_meta` object (`app.humanport/wait`)
  carrying `waited_ms` (how long THIS call itself waited — always `0` for
  `check`) and `pending_for_ms` (how long the request has been pending, or
  was pending before it was answered).
- **`await` answers as a Server-Sent Events stream, not a silently blocking
  POST.** The `Content-Type` is `text/event-stream`, with an
  `X-Accel-Buffering: no` header telling any reverse proxy in front of this
  instance not to buffer the response — buffering would defeat the whole
  point, delivering nothing to the client until the proxy's own buffer
  flushes or the connection ends. While the request stays pending, the
  stream carries periodic blank SSE comment lines (a bare `:` per line) as
  a keep-alive — this is what lets `await` hold a connection open longer
  than an idle intermediary would otherwise tolerate; the cadence is
  configured internally and is not operator-tunable in this version. When
  the request is answered, or when `await`'s own ceiling elapses with no
  answer, the stream carries exactly one final JSON-RPC response and then
  closes. A window that closes with no answer is an ORDINARY result
  (`waited_ms`/`pending_for_ms` and the request's still-pending state) —
  never an error, and never a JSON-RPC error response either way; that
  split is reserved for genuine protocol faults (unknown method, header
  mismatch), never for "nobody has answered yet."
- **Closing the connection cancels the wait.** This protocol revision has
  no client-to-server cancellation message; the client closing its end of
  an `await` connection is itself the cancellation signal, and this
  instance stops working on that wait as soon as it notices — no further
  bytes are written for a closed connection. Two `await` calls on the same
  request are independent of each other: closing one never affects the
  other.
- **If you put a reverse proxy in front of this instance,** it must not
  buffer `await`'s response and must not impose an idle/response timeout
  shorter than `HUMANPORT_MCP_AWAIT_TIMEOUT_SECONDS`. The `X-Accel-Buffering:
  no` header is this instance's own request not to buffer; whether your
  proxy honours it depends on the proxy.

## Health, readiness, and what a sustained "unhealthy" actually causes

`GET /health` answers as soon as the BEAM is up and the router is dispatching
requests — it makes no database call, so it still answers when the database
is what is wrong. `GET /ready` answers 200 only once the database is
reachable **and** every known migration has actually been applied (this
matters because migrations run at container start, before the server starts
accepting traffic — see [Environment variables](#environment-variables) and
`rel/overlays/bin/migrate`); it answers 503 with a machine-readable
`reason` — `:migrations_pending` or `{:db_unreachable, ...}` — otherwise.
**Neither endpoint restricts who may call it, and this application does not
make them host-local.** The `:health` router pipeline is `plug :accepts,
["json"]` and nothing else — no origin check, no loopback guard, and
deliberately no actor resolver, because these routes have to keep answering
when identity resolution is itself what is broken. On the reference
deployment they are unreachable from the internet only because Cloudflare
Access sits in front of the whole hostname with no path carve-out, which is
edge configuration living outside this repository. Scope Access to exclude
`/health` or `/ready` — a tempting change, since they are genuinely useful
to an external uptime monitor — or put a different reverse proxy in front of
this origin, and `/ready`'s `reason` payload (which can carry a full
`Postgrex.Error` message) becomes readable by anyone who can resolve the
hostname. If you want the host-local guarantee to hold regardless of your
edge, enforce it at your proxy or add a `conn.remote_ip` check; do not infer
it from this application's behaviour.

`compose.yaml`'s `app` service carries a `healthcheck:` that calls this same
readiness check — plus a bare check that the application's own listener
still accepts a TCP connection — through the release's `rpc` command rather
than an HTTP request, because the runner image ships neither `curl` nor
`wget`. After roughly a minute of sustained failure (`interval: 10s`,
`retries: 6`), Compose marks the `app` service `unhealthy`.

**Be precise about what that causes, because it is easy to assume more than
it does.** Standalone Docker and Compose do **not** restart a container for
becoming unhealthy — a restart policy (`restart: unless-stopped`, set on both
services in this file) fires on container **exit**: a crash, a process that
returns, a rebooted host. Restart-on-unhealthy is a Swarm/Kubernetes-style
orchestrator behaviour that plain `docker compose up` does not provide. A
sustained "no" from this healthcheck does **not** restart the container by
itself. What it actually gives you: the state is visible in
`docker compose ps` and `docker inspect` without any extra tooling, and
anything with `depends_on: condition: service_healthy` pointed at `app`
would wait on it. If you want an unhealthy container to actually restart
itself, that is a decision to make deliberately (an autoheal sidecar, an
external supervisor, or your own monitoring reacting to the visible state) —
this version does not make that decision for you, and does not ship a third
service to do it.

## What happens to a request nobody ever answers

It stays pending indefinitely and keeps appearing in the inbox's open tab.
This version has no deadlines, no expiry, and no auto-rejection — that is
intentional, not an oversight; deadlines and escalation are later work.
