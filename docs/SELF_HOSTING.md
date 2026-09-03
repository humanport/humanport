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
| `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` | `config/runtime.exs` | unset — `Resolvers.Env`, `verified? false` | The Cloudflare Access team name (just the name, not a URL — the application derives both the JWKS URL and the expected issuer from this one value, so the two can never disagree). Setting this swaps the actor resolver to `Resolvers.CloudflareAccess` and makes `HUMANPORT_CF_ACCESS_AUD` required. **Read the paragraph below before setting this.** |
| `HUMANPORT_CF_ACCESS_AUD` | `config/runtime.exs` | required if the team domain is set; unused otherwise | The AUD tag of THIS instance's own Cloudflare Access application, copied from its dashboard. Without it, a token minted for any other Access application in the same Cloudflare account would be accepted — the application refuses to start with a team domain set and no AUD tag, rather than starting half-configured. |

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

## What happens to a request nobody ever answers

It stays pending indefinitely and keeps appearing in the inbox's open tab.
This version has no deadlines, no expiry, and no auto-rejection — that is
intentional, not an oversight; deadlines and escalation are later work.
