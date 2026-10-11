#!/usr/bin/env bash
# Lab 03, Codespace side: a gateway key for Claude Code on your laptop.
#
#   bash lab/03-laptop-key.sh [--daily-usd N] [--profile NAME] [--rotate]
#
# Creates an agent key named "claude-code-laptop" (once). It's separate from
# the Codespace's "claude-code" key, so Token Monitoring shows laptop and
# Codespace usage apart, and either can be revoked on its own.
#
# The key is printed ONCE. The laptop launcher (lab/windows/
# claude-via-gateway.ps1) asks for it on first run and stores it encrypted
# for your Windows account. Lost it? --rotate issues a new one (the old one
# stops working at once); then run the launcher with -ResetKey.
#
# --profile binds the key to an agent profile (lab 01's lesson): the laptop's
# Claude Code then sees and can call only that profile's tools through the
# gateway, whatever profile it asks for. Binding applies to tool calls only;
# model calls are unaffected. Rotating keeps the binding.
set -euo pipefail

ENV_FILE="$HOME/.gateway-lab.env"
API="http://localhost:8081/api/v1"

DAILY_USD=""
PROFILE=""
ROTATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --daily-usd) DAILY_USD="${2:?--daily-usd needs a number, e.g. --daily-usd 5}"; shift 2 ;;
    --profile) PROFILE="${2:?--profile needs a profile name, e.g. --profile \"Echo Only\"}"; shift 2 ;;
    --rotate) ROTATE=1; shift ;;
    *) echo "usage: $0 [--daily-usd N] [--profile NAME] [--rotate]" >&2; exit 2 ;;
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
set_budget() {
  admin -X PATCH "$API/api-keys/$1" \
    -d "$(jq -nc --arg d "$DAILY_USD" '{limits: {daily_usd: ($d | tonumber)}}')" >/dev/null
  echo "lab: daily budget for 'claude-code-laptop' set to US\$$DAILY_USD"
}
bind_profile() {
  local pid
  pid="$(admin "$API/profiles?limit=500" | jq -r --arg n "$PROFILE" '.items[] | select(.name == $n) | .id' | head -n 1)"
  if [ -z "$pid" ]; then
    echo "lab: no profile named '$PROFILE'. Create it in the console (Profiles) or run ./examples/05-profiles/run.sh for 'Echo Only'." >&2
    exit 1
  fi
  admin -X PATCH "$API/api-keys/$1" -d "$(jq -nc --arg p "$pid" '{profile_id: $p}')" >/dev/null
  echo "lab: 'claude-code-laptop' bound to profile '$PROFILE': its tool calls are limited to that profile"
}

if [ -n "${GATEWAY_LAPTOP_KEY_ID:-}" ] && [ -z "$ROTATE" ]; then
  echo "lab: 'claude-code-laptop' already exists. Its key was shown when it was created."
  if [ -n "$DAILY_USD" ]; then set_budget "$GATEWAY_LAPTOP_KEY_ID"; fi
  if [ -n "$PROFILE" ]; then bind_profile "$GATEWAY_LAPTOP_KEY_ID"; fi
  echo "     Need it again? bash $0 --rotate   (the old key stops working)"
  exit 0
fi

if [ -n "${GATEWAY_LAPTOP_KEY_ID:-}" ]; then
  resp="$(admin -X POST "$API/api-keys/$GATEWAY_LAPTOP_KEY_ID/rotate")"
  echo "lab: rotated 'claude-code-laptop'; the previous key no longer works"
else
  resp="$(admin -X POST "$API/api-keys" -d '{"name": "claude-code-laptop", "role": "agent"}')"
  echo "lab: created agent key 'claude-code-laptop'"
fi
key="$(jq -r '.key' <<<"$resp")"
id="$(jq -r '.id // empty' <<<"$resp")"
[ -n "$id" ] || id="$GATEWAY_LAPTOP_KEY_ID"
save GATEWAY_LAPTOP_KEY_ID "$id"
if [ -n "$DAILY_USD" ]; then set_budget "$id"; fi
if [ -n "$PROFILE" ]; then bind_profile "$id"; fi

cat <<EOF

================================================================
Laptop key (shown once; copy it now):

  $key

On the laptop, start the launcher. It asks for this key on its first
run and stores it encrypted for your Windows account:

  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1
================================================================
EOF
