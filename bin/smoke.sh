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
TOTAL=18
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
log "Step 1/${TOTAL}: tear down any previous run, then build and start"
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker compose build
docker compose up -d

# ---------------------------------------------------------------- step 2 --
log "Step 2/${TOTAL}: wait for the database healthcheck, then for the application to serve"
wait_for_ready "step 2 — initial readiness"

# ---------------------------------------------------------------- step 3 --
log "Step 3/${TOTAL}: create an ask request"
out=$(http POST /api/v1/requests '{"type":"ask","title":"Which changelog entry should ship?","requester_label":"smoke-test"}')
status=$(printf '%s\n' "$out" | head -n1)
ask_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 3 — create ask" 201 "$status" "$ask_body"
ask_status=$(printf '%s' "$ask_body" | jq -r '.status')
[ "$ask_status" = "pending" ] || fail "step 3 — create ask" "expected status=pending, got $ask_status"
ASK_ID=$(printf '%s' "$ask_body" | jq -r '.id')
ASK_CONTEXT_BEFORE="$ask_body"

# ---------------------------------------------------------------- step 4 --
log "Step 4/${TOTAL}: create an approve request"
out=$(http POST /api/v1/requests '{"type":"approve","title":"Deploy release 1.4 to prod?","requester_label":"smoke-test"}')
status=$(printf '%s\n' "$out" | head -n1)
approve_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 4 — create approve" 201 "$status" "$approve_body"
approve_status=$(printf '%s' "$approve_body" | jq -r '.status')
[ "$approve_status" = "pending" ] || fail "step 4 — create approve" "expected status=pending, got $approve_status"
APPROVE_ID=$(printf '%s' "$approve_body" | jq -r '.id')

# ---------------------------------------------------------------- step 5 --
log "Step 5/${TOTAL}: read both requests back through the API"
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
log "Step 6/${TOTAL}: restart the app container and confirm both requests survive byte-identical"
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
log "Step 7/${TOTAL}: wait against the pending ask request, answer it, confirm the wait returns early"
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
log "Step 8/${TOTAL}: respond twice to the approve request — second response is a conflict"
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
log "Step 9/${TOTAL}: create a choose request over HTTP and answer it with a selection"
out=$(http POST /api/v1/requests '{"type":"choose","title":"Pick a deploy target","requester_label":"smoke-test","options":[{"id":"eu","label":"EU cluster","recommended":true},{"id":"us","label":"US cluster"}]}')
status=$(printf '%s\n' "$out" | head -n1)
choose_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 9 — create choose" 201 "$status" "$choose_body"
CHOOSE_ID=$(printf '%s' "$choose_body" | jq -r '.id')

out=$(http POST "/api/v1/requests/$CHOOSE_ID/respond" '{"selected_option_ids":["eu"]}')
status=$(printf '%s\n' "$out" | head -n1)
chosen_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 9 — answer choose" 200 "$status" "$chosen_body"
chosen=$(printf '%s' "$chosen_body" | jq -c '.result.selected_option_ids')
[ "$chosen" = '["eu"]' ] || fail "step 9 — choose result" "expected [\"eu\"], got: $chosen_body"

# ------------------------------------------------------------ MCP helpers --
# The agent-facing MCP surface (POST /mcp, revision 2026-07-28). Every call
# carries the mirrored headers the revision requires, derived from the same
# values that go into the body so the two cannot drift apart.
MCP_VERSION="2026-07-28"

# mcp_body METHOD [TOOL] [ARGS_JSON] — prints a JSON-RPC request body. Each
# call is its own HTTP request with its own response, so a fixed JSON-RPC id
# is enough here.
mcp_body() {
  jq -cn --arg method "$1" --arg tool "${2:-}" --argjson args "${3:-"{}"}" \
    --arg version "$MCP_VERSION" --argjson id 1 '
    {jsonrpc: "2.0", id: $id, method: $method,
     params: ({_meta: {"io.modelcontextprotocol/protocolVersion": $version,
                       "io.modelcontextprotocol/clientCapabilities": {}}}
              + (if $tool == "" then {} else {name: $tool, arguments: $args} end))}'
}

# mcp METHOD [TOOL] [ARGS_JSON] — prints "<status>\n<body>", like http().
mcp() {
  body=$(mcp_body "$@")
  if [ -n "${2:-}" ]; then
    resp=$(curl -sS -o /tmp/humanport-smoke-mcp.$$ -w '%{http_code}' -X POST "$BASE_URL/mcp" \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -H "mcp-protocol-version: $MCP_VERSION" -H "mcp-method: $1" -H "mcp-name: $2" -d "$body")
  else
    resp=$(curl -sS -o /tmp/humanport-smoke-mcp.$$ -w '%{http_code}' -X POST "$BASE_URL/mcp" \
      -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
      -H "mcp-protocol-version: $MCP_VERSION" -H "mcp-method: $1" -d "$body")
  fi
  printf '%s\n' "$resp"
  cat /tmp/humanport-smoke-mcp.$$
  rm -f /tmp/humanport-smoke-mcp.$$
}

# --------------------------------------------------------------- step 10 --
log "Step 10/${TOTAL}: MCP server/discover advertises ${MCP_VERSION}"
out=$(mcp server/discover)
status=$(printf '%s\n' "$out" | head -n1)
discover_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 10 — server/discover" 200 "$status" "$discover_body"
versions=$(printf '%s' "$discover_body" | jq -c '.result.supportedVersions')
[ "$versions" = "[\"$MCP_VERSION\"]" ] || fail "step 10 — supported versions" "got: $discover_body"

# --------------------------------------------------------------- step 11 --
log "Step 11/${TOTAL}: MCP tools/list returns the five tools"
out=$(mcp tools/list)
status=$(printf '%s\n' "$out" | head -n1)
tools_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 11 — tools/list" 200 "$status" "$tools_body"
tools=$(printf '%s' "$tools_body" | jq -c '[.result.tools[].name] | sort')
[ "$tools" = '["approve","ask","await","check","choose"]' ] || fail "step 11 — tool names" "got: $tools"

# --------------------------------------------------------------- step 12 --
log "Step 12/${TOTAL}: an agent asks a question over MCP"
out=$(mcp tools/call ask '{"title":"Which region should the MCP smoke test use?","requester_label":"smoke-test-mcp"}')
status=$(printf '%s\n' "$out" | head -n1)
mcp_ask_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 12 — tools/call ask" 200 "$status" "$mcp_ask_body"
[ "$(printf '%s' "$mcp_ask_body" | jq -r '.result.isError // false')" = "false" ] || \
  fail "step 12 — ask is not a tool error" "got: $mcp_ask_body"
MCP_ASK_ID=$(printf '%s' "$mcp_ask_body" | jq -r '.result.structuredContent.id')
[ "$(printf '%s' "$mcp_ask_body" | jq -r '.result.structuredContent.status')" = "pending" ] || \
  fail "step 12 — ask is pending" "got: $mcp_ask_body"

# The MCP-created request is an ordinary request: the same HTTP read sees it.
out=$(http GET "/api/v1/requests/$MCP_ASK_ID")
assert_status "step 12 — MCP request readable over HTTP" 200 "$(printf '%s\n' "$out" | head -n1)" "$out"

# --------------------------------------------------------------- step 13 --
log "Step 13/${TOTAL}: the agent awaits over MCP, a human answers, the await stream delivers it"
AWAIT_BODY=$(mcp_body tools/call await "{\"id\":\"$MCP_ASK_ID\",\"wait_seconds\":30}")
rm -f /tmp/humanport-smoke-await.$$
AWAIT_START=$(date +%s)
(curl -sS -N -X POST "$BASE_URL/mcp" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -H "mcp-protocol-version: $MCP_VERSION" -H 'mcp-method: tools/call' -H 'mcp-name: await' \
  -d "$AWAIT_BODY" >/tmp/humanport-smoke-await.$$ 2>&1) &
AWAIT_PID=$!
sleep 2
MCP_ANSWER="Use eu-central — it is where the staging data lives."
out=$(http POST "/api/v1/requests/$MCP_ASK_ID/respond" "$(jq -cn --arg a "$MCP_ANSWER" '{answer: $a}')")
assert_status "step 13 — human answers the MCP request" 200 "$(printf '%s\n' "$out" | head -n1)" "$out"

wait "$AWAIT_PID"
AWAIT_ELAPSED=$(($(date +%s) - AWAIT_START))
[ "$AWAIT_ELAPSED" -lt 20 ] || fail "step 13 — await returned early" \
  "await took ${AWAIT_ELAPSED}s — it should return within seconds of the answer, well before its 30s window"
await_final=$(sed -n 's/^data: //p' /tmp/humanport-smoke-await.$$ | tail -n1)
await_raw=$(cat /tmp/humanport-smoke-await.$$)
rm -f /tmp/humanport-smoke-await.$$
[ -n "$await_final" ] || fail "step 13 — await stream carried a final event" "stream was: $await_raw"
await_answer=$(printf '%s' "$await_final" | jq -r '.result.structuredContent.result.answer // empty')
[ "$await_answer" = "$MCP_ANSWER" ] || fail "step 13 — await delivered the answer" "got: $await_final"

# --------------------------------------------------------------- step 14 --
log "Step 14/${TOTAL}: MCP check reads the answered request"
out=$(mcp tools/call check "{\"id\":\"$MCP_ASK_ID\"}")
status=$(printf '%s\n' "$out" | head -n1)
check_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 14 — tools/call check" 200 "$status" "$check_body"
[ "$(printf '%s' "$check_body" | jq -r '.result.structuredContent.state')" = "answered" ] || \
  fail "step 14 — check sees answered" "got: $check_body"

# --------------------------------------------------------------- step 15 --
log "Step 15/${TOTAL}: MCP choose and approve round-trip; GET /mcp is refused"
out=$(mcp tools/call choose '{"title":"Pick the rollout speed","requester_label":"smoke-test-mcp","options":[{"id":"slow","label":"10% per hour"},{"id":"fast","label":"All at once"}]}')
status=$(printf '%s\n' "$out" | head -n1)
mcp_choose_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 15 — tools/call choose" 200 "$status" "$mcp_choose_body"
MCP_CHOOSE_ID=$(printf '%s' "$mcp_choose_body" | jq -r '.result.structuredContent.id')
out=$(http POST "/api/v1/requests/$MCP_CHOOSE_ID/respond" '{"selected_option_ids":["slow"]}')
assert_status "step 15 — human chooses" 200 "$(printf '%s\n' "$out" | head -n1)" "$out"
out=$(mcp tools/call check "{\"id\":\"$MCP_CHOOSE_ID\"}")
chosen=$(printf '%s\n' "$out" | tail -n +2 | jq -c '.result.structuredContent.result.selected_option_ids')
[ "$chosen" = '["slow"]' ] || fail "step 15 — check sees the choice" "got: $out"

out=$(mcp tools/call approve '{"title":"Roll out to production?","requester_label":"smoke-test-mcp"}')
status=$(printf '%s\n' "$out" | head -n1)
mcp_approve_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 15 — tools/call approve" 200 "$status" "$mcp_approve_body"
MCP_APPROVE_ID=$(printf '%s' "$mcp_approve_body" | jq -r '.result.structuredContent.id')
out=$(http POST "/api/v1/requests/$MCP_APPROVE_ID/respond" '{"decision":"reject"}')
assert_status "step 15 — human rejects" 200 "$(printf '%s\n' "$out" | head -n1)" "$out"
out=$(mcp tools/call check "{\"id\":\"$MCP_APPROVE_ID\"}")
decision=$(printf '%s\n' "$out" | tail -n +2 | jq -r '.result.structuredContent.result.decision')
[ "$decision" = "rejected" ] || fail "step 15 — check sees the rejection" "got: $out"

get_status=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/mcp")
[ "$get_status" = "405" ] || fail "step 15 — GET /mcp" "expected HTTP 405, got HTTP $get_status"

# --------------------------------------------------------------- step 16 --
log "Step 16/${TOTAL}: an agent key makes the MCP requester verified, and cannot answer itself"
# An admin key may both create and answer, so the only rule that can refuse
# it answering its own request below is the self-answer rule.
issued=$(docker compose exec -T app bin/humanport rpc 'Humanport.Release.issue_agent_key("smoke-bot", "admin")' 2>&1) || \
  fail "step 16 — issue an agent key" "$issued"
AGENT_KEY=$(printf '%s\n' "$issued" | grep -o 'hp_[A-Za-z0-9_-]*' | head -n1)
[ -n "$AGENT_KEY" ] || fail "step 16 — issue an agent key" "no token in: $issued"

body=$(mcp_body tools/call ask '{"title":"Keyed question","requester_label":"claims-to-be-root"}')
out=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/mcp" \
  -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' \
  -H "mcp-protocol-version: $MCP_VERSION" -H 'mcp-method: tools/call' -H 'mcp-name: ask' \
  -H "authorization: Bearer $AGENT_KEY" -d "$body")
status=$(printf '%s\n' "$out" | tail -n1)
keyed_body=$(printf '%s\n' "$out" | sed '$d')
assert_status "step 16 — keyed tools/call ask" 200 "$status" "$keyed_body"
[ "$(printf '%s' "$keyed_body" | jq -r '.result.structuredContent.requester_verified')" = "true" ] || \
  fail "step 16 — keyed request is verified" "got: $keyed_body"
[ "$(printf '%s' "$keyed_body" | jq -r '.result.structuredContent.requester_label')" = "smoke-bot" ] || \
  fail "step 16 — keyed request is named by its key" "got: $keyed_body"
KEYED_ID=$(printf '%s' "$keyed_body" | jq -r '.result.structuredContent.id')

self_out=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_URL/api/v1/requests/$KEYED_ID/respond" \
  -H 'content-type: application/json' -H "authorization: Bearer $AGENT_KEY" -d '{"answer":"I approve of myself"}')
self_status=$(printf '%s\n' "$self_out" | tail -n1)
[ "$self_status" = "403" ] || fail "step 16 — a key cannot answer its own request" "expected HTTP 403, got: $self_out"
printf '%s' "$self_out" | grep -q 'created itself' || \
  fail "step 16 — refused by the self-answer rule" "got: $self_out"

bad_status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/v1/requests" \
  -H 'content-type: application/json' -H 'authorization: Bearer hp_000000000000_nope' -d '{"type":"ask","title":"x"}')
[ "$bad_status" = "401" ] || fail "step 16 — a bad key is refused" "expected HTTP 401, got HTTP $bad_status"

out=$(http POST "/api/v1/requests/$KEYED_ID/respond" '{"answer":"A human answers instead."}')
assert_status "step 16 — a human answers the keyed request" 200 "$(printf '%s\n' "$out" | head -n1)" "$out"

# --------------------------------------------------------------- step 17 --
log "Step 17/${TOTAL}: a request with a deadline expires on its own, and a waiting agent sees it"
DEADLINE=$(jq -rn 'now + 3 | todate')
out=$(http POST /api/v1/requests "$(jq -cn --arg d "$DEADLINE" '{type: "approve", title: "Expires in 3s", requester_label: "smoke-test", deadline_at: $d}')")
status=$(printf '%s\n' "$out" | head -n1)
deadline_body=$(printf '%s\n' "$out" | tail -n +2)
assert_status "step 17 — create with deadline" 201 "$status" "$deadline_body"
DEADLINE_ID=$(printf '%s' "$deadline_body" | jq -r '.id')

EXPIRY_START=$(date +%s)
out=$(http GET "/api/v1/requests/$DEADLINE_ID?wait=30")
EXPIRY_ELAPSED=$(($(date +%s) - EXPIRY_START))
expired_body=$(printf '%s\n' "$out" | tail -n +2)
[ "$(printf '%s' "$expired_body" | jq -r '.status')" = "expired" ] || \
  fail "step 17 — the request expired" "after ${EXPIRY_ELAPSED}s got: $expired_body"
[ "$EXPIRY_ELAPSED" -lt 20 ] || fail "step 17 — expiry was prompt" "took ${EXPIRY_ELAPSED}s for a 3s deadline"

out=$(http POST "/api/v1/requests/$DEADLINE_ID/respond" '{"decision":"approve"}')
assert_status "step 17 — an expired request cannot be approved" 409 "$(printf '%s\n' "$out" | head -n1)" "$out"

# --------------------------------------------------------------- step 18 --
log "Step 18/${TOTAL}: tear down"
docker compose down -v --remove-orphans >/dev/null

log "PASS — all ${TOTAL} steps green."
