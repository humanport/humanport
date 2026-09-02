#!/usr/bin/env bash
# leak-guard — refuse to publish anything that does not belong in a public repository.
#
# This repository is public. Everything committed here is readable by anyone,
# permanently, including through the git history. This guard is the last check
# before that becomes true.
#
# Modes:
#   --staged           scan the staged index          (pre-commit)
#   --range A B        scan files changed between A,B (pre-push)
#   --tree             scan the whole working tree    (CI)
#
# Escape hatch: put the marker  leak-guard:allow  on a line to exempt that line.
# Use it only for text that is genuinely meant to be public.
#
# Site-specific patterns (host addresses, private repository names, anything whose
# literal value must not appear in a public file) belong in .git/leak-guard.local,
# one extended-regex per line. That file is outside the worktree and is never
# committed — which is the entire point: a deny list that ships with the repository
# publishes the very strings it is meant to protect.

set -uo pipefail

MODE="${1:---staged}"
RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 2 ] || { RED=''; YEL=''; DIM=''; OFF=''; }

findings=0

# Files that legitimately contain the patterns below (the guard, and CI that runs it).
is_exempt_file() {
  case "$1" in
    .githooks/*|.github/workflows/leak-guard.yml) return 0 ;;
    *) return 1 ;;
  esac
}

case "$MODE" in
  --staged)
    files=$(git diff --cached --name-only --diff-filter=ACMR)
    read_file() { git show ":$1" 2>/dev/null; }
    ;;
  --range)
    base="${2:-}"; head="${3:-HEAD}"
    if [ -z "$base" ] || ! git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
      files=$(git ls-tree -r --name-only "$head")
    else
      files=$(git diff --name-only --diff-filter=ACMR "$base" "$head")
    fi
    read_file() { git show "$head:$1" 2>/dev/null; }
    ;;
  --tree)
    files=$(git ls-files)
    read_file() { cat "$1" 2>/dev/null; }
    ;;
  *) echo "usage: leak-guard.sh [--staged|--range <base> <head>|--tree]" >&2; exit 2 ;;
esac

[ -z "$files" ] && exit 0

report() { # path : line : rule : excerpt
  printf '%s  %s%s%s\n' "${RED}✗${OFF}" "$1" "${DIM}:$2${OFF}" ""
  printf '     rule: %s\n' "$3"
  printf '     %s%s%s\n' "$DIM" "$4" "$OFF"
  findings=$((findings + 1))
}

# ---------------------------------------------------------------- path rules --
# Planning and proprietary artifacts belong in the private repository (ADR-0001).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    .planning/*|*/.planning/*)                 report "$f" 0 "planning tree is private (ADR-0001)" "" ;;
    PROJECT.md|ROADMAP.md|STATE.md|REQUIREMENTS.md) \
                                               report "$f" 0 "planning artifact is private (ADR-0001)" "" ;;
    *REQUIREMENTS_v[0-9]*.md|*INGEST-CONFLICTS*) \
                                               report "$f" 0 "planning artifact is private (ADR-0001)" "" ;;
    docs/adr/*|adr/*)                          report "$f" 0 "ADRs are private (ADR-0001)" "" ;;
    .env|.env.*)                               [ "$f" = ".env.example" ] || report "$f" 0 "environment file" "" ;;
    *.pem|*.key|*.p12|*.pfx|*.jks|id_rsa|id_ed25519|*.kdbx) \
                                               report "$f" 0 "credential material" "" ;;
    *.tfstate|*.tfstate.backup)                report "$f" 0 "terraform state may embed secrets" "" ;;
  esac
done <<< "$files"

# ------------------------------------------------------------- content rules --
# Each entry is  name<TAB>extended-regex.
rules=(
"private key block	-----BEGIN [A-Z ]*PRIVATE KEY-----"
"github token	gh[pousr]_[A-Za-z0-9]{30,}"
"llm provider key	\\b(sk|sk-ant)-[A-Za-z0-9_-]{20,}"
"aws access key id	\\bAKIA[0-9A-Z]{16}\\b"
"slack token	\\bxox[baprs]-[A-Za-z0-9-]{10,}"
"gitlab token	\\bglpat-[A-Za-z0-9_-]{20,}"
"google api key	\\bAIza[0-9A-Za-z_-]{35}\\b"
"generic assigned secret	(password|passwd|secret|api[_-]?key|access[_-]?token|client[_-]?secret)[[:space:]]*[:=][[:space:]]*['\"][^'\"[:space:]]{8,}['\"]"
"confidentiality marker	PROPRIETARY AND CONFIDENTIAL"
"cloudflare tunnel credential	TunnelSecret|cloudflared[^\\n]*[0-9a-f]{32}"
)

# Site-specific rules, never committed. One extended-regex per line, # for comments.
local_rules_file="$(git rev-parse --git-dir)/leak-guard.local"
local_rules=""
if [ -f "$local_rules_file" ]; then
  local_rules=$(grep -vE '^[[:space:]]*(#|$)' "$local_rules_file" || true)
fi

scan_content() { # $1 = path, stdin = content
  local f="$1" content line n name re
  content=$(cat)
  [ -z "$content" ] && return 0

  local entry
  for entry in "${rules[@]}"; do
    name="${entry%%$'\t'*}"; re="${entry#*$'\t'}"
    [ -z "$name" ] && continue
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      n=${hit%%:*}; line=${hit#*:}
      case "$line" in *leak-guard:allow*) continue ;; esac
      report "$f" "$n" "$name" "$(printf '%.100s' "$line")"
    done < <(printf '%s\n' "$content" | grep -nE -e "$re" 2>/dev/null || true)
  done

  # Public IPv4 literals. Private, loopback, link-local, multicast and the
  # RFC 5737 documentation ranges are fine; a routable address in a public
  # repository is a host disclosure. This catches our own server without the
  # address ever appearing in a committed file.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    n=${hit%%:*}; line=${hit#*:}
    case "$line" in *leak-guard:allow*) continue ;; esac
    printf '%s\n' "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | while IFS= read -r ip; do
      case "$ip" in
        0.*|10.*|127.*|169.254.*|192.168.*|255.255.255.255) continue ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
        192.0.2.*|198.51.100.*|203.0.113.*|224.*|239.*) continue ;;
        *.*.*.*) : ;;
        *) continue ;;
      esac
      # crude but effective: reject only well-formed dotted quads
      printf '%s\n' "$ip" | grep -qE '^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$' || continue
      report "$f" "$n" "routable IPv4 address (host disclosure)" "$(printf '%.100s' "$line")"
    done
  done < <(printf '%s\n' "$content" | grep -nE -e '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null || true)

  if [ -n "$local_rules" ]; then
    while IFS= read -r re; do
      [ -z "$re" ] && continue
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        n=${hit%%:*}; line=${hit#*:}
        case "$line" in *leak-guard:allow*) continue ;; esac
        report "$f" "$n" "site-specific deny rule (.git/leak-guard.local)" "$(printf '%.100s' "$line")"
      done < <(printf '%s\n' "$content" | grep -nE -e "$re" 2>/dev/null || true)
    done <<< "$local_rules"
  fi
}

while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_exempt_file "$f" && continue
  # skip binaries
  read_file "$f" | LC_ALL=C grep -qI . 2>/dev/null || continue
  scan_content "$f" < <(read_file "$f")
done <<< "$files"

if [ "$findings" -gt 0 ]; then
  cat >&2 <<MSG

${RED}leak-guard: $findings finding(s) — refusing to publish.${OFF}

This repository is PUBLIC. Anything pushed here is permanent and world-readable,
including in the git history — deleting it later does not unpublish it.

What to do:
  • Planning, ADRs, requirements, host addresses and commercial scope belong in
    the private repository, not here.
  • A real secret that already reached a commit must be ${YEL}rotated${OFF}, not just removed.
  • Text that is genuinely meant to be public: append  ${DIM}leak-guard:allow${OFF}  to the line.
  • A site-specific false positive: adjust .git/leak-guard.local.

To inspect without committing:  .githooks/leak-guard.sh --tree
MSG
  exit 1
fi

exit 0
