#!/usr/bin/env bash
# Lab 02: send Claude Code's model calls through the gateway, so each call
# shows up in the console's LLM Logs with its model, tokens, estimated cost
# and session.
#
#   bash lab/02-claude-code-via-gateway.sh [--daily-usd N]
#   source ~/.gateway-claude.env && claude
#
# What it does (safe to re-run):
#   1. creates an agent API key named "claude-code" (once), optionally with a
#      daily USD budget that the gateway enforces (--daily-usd);
#   2. writes ~/.gateway-claude.env with the two settings Claude Code reads:
#        ANTHROPIC_BASE_URL        the gateway's LLM plane (:8082)
#        ANTHROPIC_CUSTOM_HEADERS  "X-Gateway-Key: <that key>"
#      The gateway key travels in its own header and the gateway strips it
#      before forwarding, so your claude.ai login stays the credential
#      Anthropic sees and usage still counts against your subscription;
#   3. checks the route: a request with the gateway key and a deliberately
#      fake Anthropic key must pass the gateway and come back as Anthropic's
#      own 401. The gateway's own refusal says "authentication required".
set -euo pipefail

ENV_FILE="$HOME/.gateway-lab.env"
CLAUDE_ENV="$HOME/.gateway-claude.env"
API="http://localhost:8081/api/v1"
LLM="http://localhost:8082"

DAILY_USD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --daily-usd) DAILY_USD="${2:?--daily-usd needs a number, e.g. --daily-usd 5}"; shift 2 ;;
    *) echo "usage: $0 [--daily-usd N]" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1090
if [ -f "$ENV_FILE" ]; then source "$ENV_FILE"; fi
: "${GATEWAY_ADMIN_KEY:?run .devcontainer/lab-up.sh first (it saves the admin key in $ENV_FILE)}"

admin() { curl -sSf -H "Authorization: Bearer $GATEWAY_ADMIN_KEY" -H "Content-Type: application/json" "$@"; }
save() {
  { grep -v "^export $1=" "$ENV_FILE" || true; printf 'export %s=%q\n' "$1" "$2"; } > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# 1. The key Claude Code presents to the gateway.
if [ -z "${GATEWAY_CLAUDE_KEY:-}" ]; then
  body="$(jq -nc --arg d "$DAILY_USD" '{name: "claude-code", role: "agent"}
    + (if $d == "" then {} else {limits: {daily_usd: ($d | tonumber)}} end)')"
  resp="$(admin -X POST "$API/api-keys" -d "$body")"
  GATEWAY_CLAUDE_KEY="$(jq -r .key <<<"$resp")"
  GATEWAY_CLAUDE_KEY_ID="$(jq -r .id <<<"$resp")"
  save GATEWAY_CLAUDE_KEY "$GATEWAY_CLAUDE_KEY"
  save GATEWAY_CLAUDE_KEY_ID "$GATEWAY_CLAUDE_KEY_ID"
  echo "lab: created agent key 'claude-code' ($(jq -r .prefix <<<"$resp")…)${DAILY_USD:+ with a daily budget of US\$$DAILY_USD}"
else
  echo "lab: reusing agent key 'claude-code' from $ENV_FILE"
  if [ -n "$DAILY_USD" ]; then
    admin -X PATCH "$API/api-keys/$GATEWAY_CLAUDE_KEY_ID" \
      -d "$(jq -nc --arg d "$DAILY_USD" '{limits: {daily_usd: ($d | tonumber)}}')" >/dev/null
    echo "lab: daily budget set to US\$$DAILY_USD"
  fi
fi

# 2. Claude Code's settings, in a file only you can read.
(
  umask 077
  cat > "$CLAUDE_ENV" <<EOF
# Route Claude Code's model calls through the gateway lab:
#   source ~/.gateway-claude.env && claude
# To go direct again, open a new terminal (or unset both variables).
export ANTHROPIC_BASE_URL=$LLM
export ANTHROPIC_CUSTOM_HEADERS="X-Gateway-Key: $GATEWAY_CLAUDE_KEY"
EOF
)
echo "lab: wrote $CLAUDE_ENV"

# 3. Route check. The Anthropic key is deliberately fake, so the call can
#    never be served or billed; all it can prove is the route.
FAKE_ANTHROPIC_KEY="sk-ant-lab-route-check-0000000000"
out="$(curl -sS -w '\n%{http_code}' -X POST "$LLM/v1/messages" \
  -H "X-Gateway-Key: $GATEWAY_CLAUDE_KEY" \
  -H "x-api-key: $FAKE_ANTHROPIC_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}')"
code="${out##*$'\n'}"
body="${out%$'\n'*}"

if [[ "$body" == *"authentication required"* ]]; then
  echo "FAIL: the gateway refused the 'claude-code' key (revoked in the console?)." >&2
  echo "      Remove it and re-run:  sed -i '/GATEWAY_CLAUDE_KEY/d' $ENV_FILE && bash $0" >&2
  exit 1
elif [ "$code" = "401" ] && [[ "$body" == *"authentication_error"* ]]; then
  echo "PASS: the gateway accepted the key and forwarded the call; Anthropic rejected the fake key (401), as intended."
else
  echo "FAIL: unexpected answer (HTTP $code): $body" >&2
  exit 1
fi

cat <<EOF

================================================================
Claude Code is ready to run through the gateway.

  source $CLAUDE_ENV
  claude

Inside Claude Code, /status should show "Anthropic base URL: $LLM"
and your claude.ai login. Then open the console's LLM Logs page: each
model call appears with its model, tokens, estimated cost and session.
The route check above is already there as a 401 row.
================================================================
EOF
