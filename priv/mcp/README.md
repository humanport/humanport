# Vendored MCP JSON Schema

`schema-2026-07-28.json` is a byte-for-byte, unmodified copy of the official
Model Context Protocol JSON Schema for revision `2026-07-28`, fetched from
`modelcontextprotocol/modelcontextprotocol`. It is pinned by SHA-256 in
`SHA256SUMS`, which also records the exact upstream URL, the upstream
directory (`schema/2026-07-28/`) and the fetch date.

## Why this file exists (D-08a)

HumanPort implements MCP by hand rather than through a library (D-08,
`02.1-CONTEXT.md`). That decision makes spec-tracking a permanent local cost:
"follows the official spec" has to be a passing test, not a claim. This file
is the oracle every contract test in the phase validates against
(`Humanport.McpSchema`, `test/support/mcp_schema.ex`). A spec revision shows
up here as a digest mismatch — a loud, failing check — rather than as silent
drift nobody notices.

Do not hand-edit this file. Do not reformat it, strip its `$schema` key, or
prune unused definitions. An oracle that has been edited is no longer an
oracle.

## The draft-07 substitution — validated against THIS pinned revision only

`Humanport.McpSchema` validates payloads by substituting this file's
`$schema` value with `http://json-schema.org/draft-07/schema#` **in memory
only** (the file on disk, and its pinned digest, are never touched — that is
what keeps the pin meaningful). The vendored schema itself declares
`https://json-schema.org/draft/2020-12/schema`; the approved validator
library (`ex_json_schema`) supports draft 4/6/7 only.

This substitution is sound **for this exact pinned revision**, not in
general. At planning time (2026-09-03) the vendored file was audited keyword
by keyword against the pin above:

- `$schema` declares draft 2020-12; uses `$defs` (155 definitions), not
  `definitions`.
- All 277 `$ref` values are plain JSON Pointers of the shape `#/$defs/…` —
  pointer resolution does not care what the intermediate key is named, so
  `$defs` under a draft-07 validator resolves identically to `definitions`
  under draft-07.
- Zero occurrences of the draft-07 tuple form `"items": [ … ]`.
- Zero occurrences of any keyword that exists ONLY in 2019-09/2020-12 and
  that a draft-07 validator would silently ignore rather than error on:
  `prefixItems`, `unevaluatedProperties`, `unevaluatedItems`,
  `dependentSchemas`, `dependentRequired`, `minContains`, `maxContains`,
  `$dynamicRef`, `$dynamicAnchor`, `$anchor`, `$recursiveRef`.

That audit is what makes the substitution sound rather than merely
convenient: every keyword this phase's definitions actually use has
identical semantics under draft 7 and draft 2020-12.

**Re-vendoring a newer schema requires repeating that audit.** A future
revision that introduces any keyword in the list above would be silently
ignored by a draft-07 validator — accepting payloads the real 2020-12 schema
would reject. That is precisely the failure this oracle exists to prevent.
Re-run the keyword grep against the new file before trusting the
substitution again; do not assume it still holds.

## Refreshing this file

1. Fetch the new revision's `schema.json` from the upstream repository.
2. Repeat the keyword audit above against the new file.
3. Replace `schema-2026-07-28.json` (rename it for the new revision) and
   recompute `SHA256SUMS` in the **same commit**. Expect contract tests to
   move — that is the point of pinning.
4. Update this file's revision references.

## Advertised protocol revisions

TBD — filled in by `02.1-01-PLAN.md` Task 3 once the client-revision finding
(`.planning/phases/02.1-humanport-in-the-loop/02.1-CLIENT-REVISION.md`) is
recorded and the owner has decided how many revisions `server/discover`
advertises.
