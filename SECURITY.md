# Security Policy

HumanPort mediates approvals and authoritative human decisions for autonomous
systems. Security issues in it can have real-world consequences, and we take
them seriously.

## Reporting a vulnerability

**Please do not report security issues in public GitHub issues, discussions or
pull requests.**

Use GitHub's private vulnerability reporting for this repository
(*Security → Report a vulnerability*).

Please include:

- a description of the issue and its impact;
- the affected version or commit;
- reproduction steps or a proof of concept;
- any suggested mitigation.

## What to expect

- We aim to acknowledge a report within 3 business days.
- We will keep you updated while we investigate and prepare a fix.
- We will credit reporters in the release notes unless you prefer otherwise.

## Scope

In scope: authentication and authorization, tenant isolation, request integrity
and replay protection, audit trail integrity, idempotency handling, and the
REST, MCP and A2A adapters.

Out of scope: findings that require an already-compromised host or database,
and issues in third-party dependencies without a demonstrated impact on
HumanPort (please report those upstream).
