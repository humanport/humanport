# Contributing to HumanPort

Thanks for your interest in HumanPort. This repository is the canonical source
of the HumanPort open-source core.

## Ground rules

- **This repository is fully public**, including its documentation and history.
  Never commit credentials, customer data, internal planning material, or
  anything that belongs to a private deployment.
- **The public core must stand alone.** It must compile, test, run and self-host
  without access to any private repository. A dependency from this repository to
  proprietary code is not acceptable.
- **Protocol interoperability stays open.** Do not move REST, OpenAPI, MCP or A2A
  capability behind a commercial boundary.

## First: enable the hooks

`core.hooksPath` is local configuration and is not cloned, so a fresh checkout has
no hooks. Enable them once, before your first commit:

```bash
git config core.hooksPath .githooks
```

This installs `leak-guard`, which refuses to commit or push anything that does not
belong in a public repository — credential material, host addresses, and planning
artifacts. To scan without committing:

```bash
.githooks/leak-guard.sh --tree
```

The same check runs in CI, where it cannot be skipped, and GitHub secret scanning
with push protection is enabled on this repository. If the guard flags a line that
is genuinely meant to be public, append the marker `leak-guard:allow` to it. If a
real secret ever reaches a commit, rotate it — removing the line does not unpublish
it.

## How changes reach `main`

`main` is protected by a ruleset: it cannot be deleted, cannot be force-pushed, and
cannot be updated by a commit that has not passed the `leak-guard` check. That check
is what stands between a mistake and a permanent public record, so it runs before
publication rather than after.

In practice this means a commit is checked on a branch first:

```bash
git switch -c my-change
# ... work, commit ...
git push -u origin my-change     # leak-guard runs here
```

Then either open a pull request, or — once the check is green — fast-forward `main`:

```bash
git switch main && git merge --ff-only my-change && git push
```

Pushing a fresh commit straight to `main` is rejected, because nothing has verified
it yet. That rejection is the rule working, not a misconfiguration.

**If the ruleset itself has to come off** — a genuine emergency, not a hurry — set it
to `evaluate` rather than deleting it, and put it back the same day:

```bash
gh api -X PUT repos/humanport/humanport/rulesets/22109140 -f enforcement=evaluate
gh api -X PUT repos/humanport/humanport/rulesets/22109140 -f enforcement=active
```

## Development

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
```

CI validates the complete open-source product without any private code.

## Design conventions

- Security-sensitive business logic belongs in Ash resources/actions or dedicated
  domain modules — never only in a LiveView or controller.
- Security-sensitive interaction UI belongs in the `HumanPort.UI.*` component
  layer, not in ad-hoc raw controls.
- The domain model stays protocol-neutral. Protocol specifics live in adapters.

## Pull requests

1. Open an issue first for anything larger than a fix, so we can agree on the
   approach before you invest time.
2. Keep commits focused and messages descriptive.
3. Add or update tests, including protocol contract tests where relevant.
4. Update documentation in the same pull request.

## Licensing of contributions

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), including its explicit patent grant.
