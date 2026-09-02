#!/bin/sh
# The scripted, repeatable form of the OPS-01 acceptance run.
#
# This is a manual-only check by nature — it exercises the image build, the
# healthcheck ordering, and volume creation, none of which any in-process
# test reproduces. Scripting it is what makes it repeatable rather than
# ceremonial. It is idempotent (a failed run leaves containers/a volume
# behind on purpose, for `docker compose logs app`; step 1 of the NEXT run
# always tears down first, so re-running always starts clean) and fails
# loudly, naming the step it failed at.
#
# Usage: bin/smoke.sh (run from the repository root, or anywhere — it cd's
# to its own location first).
set -eu

cd -P -- "$(dirname -- "$0")/.."

BASE_URL="http://localhost:4000"
API="$BASE_URL/api/v1/requests"

log() {
  printf '\033[36m==>\033[0m %s\n' "$1"
}

fail() {
  printf '\033[31mFAIL\033[0m at step: %s\n' "$1" >&2
  printf '     %s\n' "$2" >&2
  printf '     Containers were left running for inspection: docker compose logs app\n' >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'FAIL: this script requires "%s" on PATH.\n' "$1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl
require_cmd jq

# http METHOD PATH [JSON_BODY]
# Prints "<status>\n<body>" to stdout.
http() {
  method="$1"
  path="$2"
  body="${3:-}"
  if [ -n "$body" ]; then
    resp=$(curl -sS -o /tmp/humanport-smoke-body.$$ -w '%{http_code}' \
      -X "$method" "$BASE_URL$path" \
      -H 'content-type: application/json' -d "$body")
  else
    resp=$(curl -sS -o /tmp/humanport-smoke-body.$$ -w '%{http_code}' \
      -X "$method" "$BASE_URL$path")
  fi
  printf '%s\n' "$resp"
  cat /tmp/humanport-smoke-body.$$
  rm -f /tmp/humanport-smoke-body.$$
}

# assert_status STEP EXPECTED ACTUAL BODY
assert_status() {
  [ "$2" = "$3" ] || fail "$1" "expected HTTP $2, got HTTP $3 — body: $4"
}

wait_for_ready() {
  step="$1"
  i=0
  while ! curl -sf "$BASE_URL/requests" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 60 ] || fail "$step" "the application never became ready within 180s"
    sleep 3
  done
}

# ---------------------------------------------------------------- step 1 --
log "Step 1/10: tear down any previous run, then build and start"
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker compose build
docker compose up -d

# ---------------------------------------------------------------- step 2 --
log "Step 2/10: wait for the database healthcheck, then for the application to serve"
wait_for_ready "step 2 — initial readiness"

# ---------------------------------------------------------------- step 3 --
log "Step 3/10: create an ask request"
out=$(http POST /api/v1/requests '{"type":"ask","title":"Which changelog entry should ship?","requester_label":"smoke-test"}')
status=$(printf '%s\n' "$out" | head -n1)
ask_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 3 — create ask" 201 "$status" "$ask_body"
ask_status=$(printf '%s' "$ask_body" | jq -r '.status')
[ "$ask_status" = "pending" ] || fail "step 3 — create ask" "expected status=pending, got $ask_status"
ASK_ID=$(printf '%s' "$ask_body" | jq -r '.id')
ASK_CONTEXT_BEFORE="$ask_body"

# ---------------------------------------------------------------- step 4 --
log "Step 4/10: create an approve request"
out=$(http POST /api/v1/requests '{"type":"approve","title":"Deploy release 1.4 to prod?","requester_label":"smoke-test"}')
status=$(printf '%s\n' "$out" | head -n1)
approve_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 4 — create approve" 201 "$status" "$approve_body"
approve_status=$(printf '%s' "$approve_body" | jq -r '.status')
[ "$approve_status" = "pending" ] || fail "step 4 — create approve" "expected status=pending, got $approve_status"
APPROVE_ID=$(printf '%s' "$approve_body" | jq -r '.id')

# ---------------------------------------------------------------- step 5 --
log "Step 5/10: read both requests back through the API"
out=$(http GET "/api/v1/requests/$ASK_ID")
status=$(printf '%s\n' "$out" | head -n1)
ask_read="$(printf '%s\n' "$out" | tail -n +2)"
assert_status "step 5 — read ask" 200 "$status" "$ask_read"

out=$(http GET "/api/v1/requests/$APPROVE_ID")
status=$(printf '%s\n' "$out" | head -n1)
approve_read="$(printf '%s\n' "$out" | tail -n +2)"
assert_status "step 5 — read approve" 200 "$status" "$approve_read"

# Snapshot the pre-restart shape of both rows — CORE-01 in its deployed form
# (step 6) compares against exactly this, read through the same API.
ASK_BEFORE_RESTART=$(printf '%s' "$ask_read" | jq -S '{id, state, context, inserted_at, title, requester_label}')
APPROVE_BEFORE_RESTART=$(printf '%s' "$approve_read" | jq -S '{id, state, context, inserted_at, title, requester_label}')

# ---------------------------------------------------------------- step 6 --
log "Step 6/10: restart the app container and confirm both requests survive byte-identical"
docker compose restart app >/dev/null
wait_for_ready "step 6 — post-restart readiness"

out=$(http GET "/api/v1/requests/$ASK_ID")
status=$(printf '%s\n' "$out" | head -n1)
ask_after=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 6 — re-read ask" 200 "$status" "$ask_after"
ASK_AFTER_RESTART=$(printf '%s' "$ask_after" | jq -S '{id, state, context, inserted_at, title, requester_label}')
[ "$ASK_BEFORE_RESTART" = "$ASK_AFTER_RESTART" ] || fail "step 6 — ask survives restart" \
  "before: $ASK_BEFORE_RESTART / after: $ASK_AFTER_RESTART"

out=$(http GET "/api/v1/requests/$APPROVE_ID")
status=$(printf '%s\n' "$out" | head -n1)
approve_after=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 6 — re-read approve" 200 "$status" "$approve_after"
APPROVE_AFTER_RESTART=$(printf '%s' "$approve_after" | jq -S '{id, state, context, inserted_at, title, requester_label}')
[ "$APPROVE_BEFORE_RESTART" = "$APPROVE_AFTER_RESTART" ] || fail "step 6 — approve survives restart" \
  "before: $APPROVE_BEFORE_RESTART / after: $APPROVE_AFTER_RESTART"

# ---------------------------------------------------------------- step 7 --
log "Step 7/10: wait against the pending ask request, answer it, confirm the wait returns early"
rm -f /tmp/humanport-smoke-wait.$$
WAIT_START=$(date +%s)
(curl -sS "$BASE_URL/api/v1/requests/$ASK_ID?wait=30" >/tmp/humanport-smoke-wait.$$ 2>&1) &
WAIT_PID=$!
sleep 1
out=$(http POST "/api/v1/requests/$ASK_ID/respond" '{"answer":"Ship entry #42 — it is the only user-facing fix in this release."}')
status=$(printf '%s\n' "$out" | head -n1)
respond_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 7 — answer the ask request" 200 "$status" "$respond_body"

wait "$WAIT_PID"
WAIT_ELAPSED=$(($(date +%s) - WAIT_START))
[ "$WAIT_ELAPSED" -lt 20 ] || fail "step 7 — wait returned early" \
  "the ?wait=30 call took ${WAIT_ELAPSED}s to return — it should have returned within a couple seconds of the answer, well before the 30s ceiling"
wait_body=$(cat /tmp/humanport-smoke-wait.$$)
rm -f /tmp/humanport-smoke-wait.$$
wait_answer=$(printf '%s' "$wait_body" | jq -r '.result.answer // empty')
[ "$wait_answer" = "Ship entry #42 — it is the only user-facing fix in this release." ] || \
  fail "step 7 — wait returned the answer" "got: $wait_body"

# ---------------------------------------------------------------- step 8 --
log "Step 8/10: respond twice to the approve request — second response is a conflict"
out=$(http POST "/api/v1/requests/$APPROVE_ID/respond" '{"decision":"approve"}')
status=$(printf '%s\n' "$out" | head -n1)
first_respond_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 8 — first response to approve request" 200 "$status" "$first_respond_body"

out=$(http POST "/api/v1/requests/$APPROVE_ID/respond" '{"decision":"reject"}')
status=$(printf '%s\n' "$out" | head -n1)
second_respond_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 8 — duplicate response is a conflict" 409 "$status" "$second_respond_body"
second_code=$(printf '%s' "$second_respond_body" | jq -r '.error.code // empty')
[ "$second_code" = "conflict" ] || fail "step 8 — duplicate response error code" "got: $second_respond_body"

# ---------------------------------------------------------------- step 9 --
log "Step 9/10: creating a choose request is refused as not implemented"
out=$(http POST /api/v1/requests '{"type":"choose","title":"Pick a deploy target","requester_label":"smoke-test"}')
status=$(printf '%s\n' "$out" | head -n1)
choose_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 9 — choose is refused" 422 "$status" "$choose_body"
choose_code=$(printf '%s' "$choose_body" | jq -r '.error.code // empty')
[ "$choose_code" = "not_implemented" ] || fail "step 9 — choose error code" "got: $choose_body"

# --------------------------------------------------------------- step 10 --
log "Step 10/10: tear down"
docker compose down -v --remove-orphans >/dev/null

log "PASS — all 10 steps green."
