#!/usr/bin/env bash
# Lab 01: a key bound to a profile cannot escape it.
#
# Run in the Codespace after .devcontainer/lab-up.sh and
# examples/05-profiles/run.sh (which creates the "Echo Only" profile:
# everything__echo and everything__get-sum, nothing else).
#
# It creates two agent keys, one bound to "Echo Only" and one unbound, calls
# tools through the MCP plane (:8080) with each, prints what the gateway
# decided, and revokes both keys at the end. No secrets are printed.
set -euo pipefail

ENV_FILE="$HOME/.gateway-lab.env"
# shellcheck disable=SC1090
if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; fi
: "${GATEWAY_ADMIN_KEY:?run .devcontainer/lab-up.sh first (it saves the admin key in $ENV_FILE)}"

API="http://localhost:8081/api/v1"
MCP="http://localhost:8080/mcp"
PASS=0
FAIL=0

admin() { curl -sSf -H "Authorization: Bearer $GATEWAY_ADMIN_KEY" -H "Content-Type: application/json" "$@"; }

# call KEY TOOL [PROFILE_HEADER]: one stateless tools/call; prints the
# JSON-RPC response (SSE "data:" framing removed if the server used it).
call() {
  local key="$1" tool="$2" profile="${3:-}" hdr=()
  if [ -n "$profile" ]; then hdr=(-H "X-Agent-Profile-Name: $profile"); fi
  curl -sS "$MCP" \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${hdr[@]+"${hdr[@]}"} \
    -d "$(jq -nc --arg t "$tool" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:(if $t=="everything__echo" then {message:"hello from lab 01"} else {} end)}}')" |
    sed -e 's/^data: //' -e '/^event:/d' -e '/^$/d'
}

# expect LABEL WANT RESPONSE: WANT is "allow" or a JSON-RPC error code.
expect() {
  local label="$1" want="$2" resp="$3" got msg
  # Only a JSON-RPC result counts as allowed; anything else (empty, null,
  # HTML, a proxy error) is "unexpected", never a pass.
  got="$(jq -r 'if (type=="object" and .error) then (.error.code|tostring) elif (type=="object" and .result) then "allow" else "unexpected" end' <<<"$resp" 2>/dev/null || echo "unexpected")"
  [ -n "$got" ] || got="unexpected"
  msg="$(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); printf '  PASS  %-58s -> %s%s\n' "$label" "$got" "${msg:+  ($msg)}"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %-58s -> got %s, wanted %s\n        %s\n' "$label" "$got" "$want" "$resp"
  fi
}

echo "== Setup"
PROFILE_ID="$(admin "$API/profiles?limit=500" | jq -r '.items[] | select(.name=="Echo Only") | .id' | head -n 1)"
if [ -z "$PROFILE_ID" ]; then
  echo "No 'Echo Only' profile yet. Run ./examples/05-profiles/run.sh first." >&2
  exit 1
fi
echo "  'Echo Only' profile: $PROFILE_ID"

bound="$(admin -X POST "$API/api-keys" -d "$(jq -nc --arg p "$PROFILE_ID" '{name:"lab01-bound",role:"agent",profile_id:$p}')")"
unbound="$(admin -X POST "$API/api-keys" -d '{"name":"lab01-unbound","role":"agent"}')"
BOUND_KEY="$(jq -r .key <<<"$bound")"; BOUND_ID="$(jq -r .id <<<"$bound")"
UNBOUND_KEY="$(jq -r .key <<<"$unbound")"; UNBOUND_ID="$(jq -r .id <<<"$unbound")"
echo "  bound key   $(jq -r .prefix <<<"$bound")…  -> Echo Only"
echo "  unbound key $(jq -r .prefix <<<"$unbound")…  -> no binding"
revoke() { admin -X DELETE "$API/api-keys/$BOUND_ID" >/dev/null 2>&1 || true; admin -X DELETE "$API/api-keys/$UNBOUND_ID" >/dev/null 2>&1 || true; }
trap revoke EXIT

echo
echo "== The bound key stays inside 'Echo Only'"
expect "bound, no header, echo (granted)"                  allow  "$(call "$BOUND_KEY" everything__echo)"
expect "bound, no header, get-env (not granted)"           -32003 "$(call "$BOUND_KEY" everything__get-env)"
expect "bound, header 'Full Access', get-env (escape try)" -32003 "$(call "$BOUND_KEY" everything__get-env "Full Access")"

echo
echo "== The unbound key picks its own profile"
expect "unbound, header 'Echo Only', get-env"              -32003 "$(call "$UNBOUND_KEY" everything__get-env "Echo Only")"
resp="$(call "$UNBOUND_KEY" everything__get-env "Full Access")"
expect "unbound, header 'Full Access', get-env"            allow  "$resp"
# get-env returns the sample server's environment variables. Count the ones
# whose NAMES look sensitive; never print values.
names="$(jq -r '[.result.content[]?.text // empty] | join("\n")' <<<"$resp" | grep -oE '"?[A-Z][A-Z0-9_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Z0-9_]*"?' | tr -d '"' | sort -u | paste -sd' ' - || true)"
echo "        get-env exposed $(wc -w <<<"$names" | tr -d ' ') sensitive-looking variable name(s)${names:+: $names} (values not shown)"

echo
echo "== Revocation is immediate"
revoke
trap - EXIT
resp="$(call "$BOUND_KEY" everything__echo)"
expect "revoked bound key, echo"                           -32001 "$resp"

echo
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
