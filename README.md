# HumanPort

**The open human control plane for AI agents.**

HumanPort is a protocol-neutral human interaction runtime. When an autonomous
agent cannot, should not, or is not allowed to continue without a human, it
creates a durable *human request* — without needing to know which human to
contact, which interface they use, or how long the answer will take.

```text
MCP  connects models and agents to tools.
A2A  connects agents and agent services.
MHS  will connect models to physical devices.

HumanPort connects these systems to humans.
```

> **Status:** early development. The API is not yet stable.

## What HumanPort owns

The whole lifecycle between the agent's request and the human's response:

identity · authorization · routing · presentation · notification · deadlines ·
escalation · response integrity · delivery · auditability

HumanPort is **not** an agent framework and **not** merely an approval gateway.

## Interaction types

| Type       | Meaning                                                |
| ---------- | ------------------------------------------------------ |
| `ask`      | Get free-form information from a human.                 |
| `choose`   | Have a human select from a bounded set of options.      |
| `approve`  | Obtain an explicit, attributable approval or rejection. |
| `escalate` | Move a request to a wider or higher-authority audience. |

## Design principles

- **Protocol neutral** — the domain model never depends on MCP, A2A, REST or
  MHS semantics. Protocol adapters translate in and out of a canonical
  `HumanRequest`.
- **Stateless protocol handling** — no feature depends on a sticky session. Every
  durable interaction is addressable by an explicit identifier, and any
  application instance can serve the next request.
- **Durable state, disposable compute** — business-critical state survives
  process, node and deployment loss.
- **Audit is a product feature** — not a debug log.
- **Secure by default** — multi-tenant isolation, request integrity and replay
  protection are baseline, not add-ons.
- **API first** — the UI is one client of the same API.

## Technology

Elixir · Erlang/OTP · Phoenix · Ash Framework · Phoenix LiveView ·
Petal Components · Tailwind CSS · PostgreSQL · Oban · OpenTelemetry

PostgreSQL is the only required infrastructure dependency. No Redis, Kafka or
RabbitMQ is needed to run HumanPort.

## Self-hosting

The open-source edition is a complete, self-hostable HumanPort deployment — not
a demo and not an artificially limited edition. Protocol interoperability
(REST, OpenAPI, MCP, A2A) is open source and will stay open source.

```bash
git clone https://github.com/humanport/humanport.git
cd humanport
docker compose up
```

That starts HumanPort and PostgreSQL, and nothing else — no variable has to be
exported first. Open <http://localhost:4000/requests> once it reports it is
serving.

An agent creates a request the same way, over plain HTTP — no SDK required:

```bash
curl -s http://localhost:4000/api/v1/requests \
  -H 'content-type: application/json' \
  -d '{"type":"approve","title":"Deploy release 1.4 to prod?","requester_label":"claude-code"}'
```

It appears in the inbox live, without a reload. Full details — what this
version does and does not require, what it does and does not guarantee, and
the environment variables you can set — are in
[`docs/SELF_HOSTING.md`](docs/SELF_HOSTING.md).

## Open core

HumanPort follows an open-core model:

> **Interoperability is open. Operations and enterprise governance are commercial.**

This repository is the canonical source of truth for the HumanPort open-source
core. A separate commercial edition (managed cloud, billing, enterprise identity
lifecycle, long-term managed audit retention) builds *on top of* this repository.
This repository never depends on it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go to the process in
[SECURITY.md](SECURITY.md) — please do not open public issues for them.

## License

[Apache License 2.0](LICENSE) — `SPDX-License-Identifier: Apache-2.0`
