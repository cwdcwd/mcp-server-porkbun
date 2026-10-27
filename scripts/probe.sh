#!/bin/sh
# Negative-control probe ladder for the Porkbun MCP access gate.
#
# Deliberately credential-free: every check below must PASS without any Porkbun
# key. A well-formed but fake key pair is intentionally sent - the connector
# validates it upstream against Porkbun /ping and must reject it, proving the
# gate is not merely a header-presence check. Real-credential serving is NOT
# exercised here (owner key; verified in the verification stage).
#
# Usage: scripts/probe.sh [base-url]      (default http://127.0.0.1:3008)
# Env override: PROBE_BASE=http://host:port scripts/probe.sh
set -u
BASE="${1:-${PROBE_BASE:-http://127.0.0.1:3008}}"
PASS=0
FAIL=0

expect() { # expect <http_code_want> <label> <curl args...>
  want="$1"; label="$2"; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@")
  if [ "$got" = "$want" ]; then
    echo "PASS  $label  (HTTP $got)"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $label  (want HTTP $want, got HTTP $got)"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Health endpoint served BEFORE the gate (connector source: /health first).
expect 200 "GET /health serves pre-gate health" "$BASE/health"

# 2. No credentials at all - must be rejected before any MCP traffic.
expect 401 "GET /mcp with no credentials rejected" "$BASE/mcp"
expect 401 "POST /mcp with no credentials rejected" -X POST \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  "$BASE/mcp"

# 3. Malformed bearer - not a Porkbun credential shape - rejected locally.
expect 401 "POST /mcp with malformed bearer rejected" -X POST \
  -H 'Authorization: Bearer something-not-a-porkbun-credential' \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  "$BASE/mcp"

# 4. Well-formed key-pair bearer WITHOUT a fake marker, wrong length - rejected
#    locally by shape (length check). No upstream call needed for this one.
expect 401 "POST /mcp with wrong-length pk1/sk1 pair rejected" -X POST \
  -H 'Authorization: Bearer pk1_short:sk1_short' \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  "$BASE/mcp"

# 5. Well-formed, wrong-credential key pair - validated UPSTREAM via /ping and
#    rejected. This proves the gate validates against the Porkbun API.
expect 401 "POST /mcp with fake-length pk1/sk1 pair rejected after upstream validation" -X POST \
  -H 'Authorization: Bearer pk1_notarealkey000000000000000000000000:sk1_notarealsecret000000000000000000' \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  "$BASE/mcp"

# 6. Unknown path (gate behavior on the router, pre-auth) - 404.
expect 404 "GET /unknown-path is 404" "$BASE/not-a-real-endpoint"

echo
echo "probe summary: PASS=$PASS FAIL=$FAIL (base=$BASE)"
[ "$FAIL" = 0 ]