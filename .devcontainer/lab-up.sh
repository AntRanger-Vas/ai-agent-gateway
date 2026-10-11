#!/usr/bin/env bash
# Starts the AI Agent Gateway lab in this Codespace. Safe to re-run (after a
# Codespace restart, for example):
#   1. creates your own master key once, outside the repo;
#   2. runs Tuskira's quickstart (examples/01-quickstart/run.sh): the sample
#      MCP server, the gateway and Postgres, an admin API key, one connector,
#      and a first tool call through the gateway;
#   3. creates the console user "admin" on the first run and prints its
#      one-time password;
#   4. prints where the console is.
#
# Options:
#   --analytics  also run ClickHouse (and the OTel collector and Jaeger from
#                examples/08-observability), which the console's Overview
#                dashboard, Access Logs and Session Timeline read from. The
#                choice is remembered, so later runs keep it.
set -euo pipefail

ANALYTICS_ARG=""
for arg in "$@"; do
  case "$arg" in
    --analytics) ANALYTICS_ARG=1 ;;
    *) echo "usage: $0 [--analytics]" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$HOME/.gateway-lab.env" # outside the repo, so it is never committed
COMPOSE=(docker compose -f "$ROOT/deploy/docker-compose.yml")

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

# save NAME VALUE: keep a value for later runs and new terminals.
save() {
  { grep -v "^export $1=" "$ENV_FILE" || true; printf 'export %s=%q\n' "$1" "$2"; } > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# 1. The master key encrypts every credential the gateway stores. Without one,
#    the compose file falls back to a fixed demo key that is published in the
#    repo, so set ours before the first start.
if [ -z "${GATEWAY_MASTER_KEY:-}" ]; then
  GATEWAY_MASTER_KEY="$(openssl rand -base64 32)"
  save GATEWAY_MASTER_KEY "$GATEWAY_MASTER_KEY"
  echo "lab: created your own master key in $ENV_FILE"
fi
export GATEWAY_MASTER_KEY

cd "$ROOT"

# Analytics: start ClickHouse with the same overlay the quickstart uses to
# preserve it, so the quickstart below finds it running and keeps it (and
# never recreates the gateway without our master key).
if [ -n "$ANALYTICS_ARG" ] && [ -z "${GATEWAY_LAB_ANALYTICS:-}" ]; then
  GATEWAY_LAB_ANALYTICS=1
  save GATEWAY_LAB_ANALYTICS 1
fi
if [ -n "${GATEWAY_LAB_ANALYTICS:-}" ]; then
  echo "lab: starting the analytics stack (ClickHouse, OTel collector, Jaeger)"
  GATEWAY_SINKS_CLICKHOUSE_ENABLED=true docker compose \
    -f deploy/docker-compose.yml -f examples/08-observability/docker-compose.observability.yml \
    --profile analytics up --build -d
fi

# 2. Tuskira's quickstart. It reuses GATEWAY_ADMIN_KEY when set; otherwise it
#    bootstraps an admin key and prints it as "Admin key:  gk_...".
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
GATEWAY_ADMIN_KEY="${GATEWAY_ADMIN_KEY:-}" ./examples/01-quickstart/run.sh 2>&1 | tee "$log"
key="$(sed -n 's/^Admin key:  *//p' "$log" | tail -n 1)"
if [ -n "$key" ] && [ "$key" != "${GATEWAY_ADMIN_KEY:-}" ]; then
  GATEWAY_ADMIN_KEY="$key"
  save GATEWAY_ADMIN_KEY "$GATEWAY_ADMIN_KEY"
fi

# 3. A console user, on the first run only.
password=""
if [ -z "${GATEWAY_LAB_CONSOLE_USER:-}" ]; then
  echo
  echo "lab: creating console user 'admin'"
  if password="$("${COMPOSE[@]}" exec -T gateway /gateway create-user -tenant default -username admin -role admin)"; then
    save GATEWAY_LAB_CONSOLE_USER admin
  else
    password=""
    echo "lab: could not create 'admin' (it may already exist). To set a new one-time password:"
    echo "     ${COMPOSE[*]} exec gateway /gateway reset-password -tenant default -username admin"
  fi
fi

# 4. Where to go next.
if [ -n "${CODESPACE_NAME:-}" ]; then
  console="https://${CODESPACE_NAME}-8081.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
else
  console="http://localhost:8081"
fi
if [ -n "${GATEWAY_LAB_ANALYTICS:-}" ]; then
  analytics_line="Analytics:  on (Overview, Access Logs, Session Timeline)"
  stop_cmd="docker compose -f deploy/docker-compose.yml -f examples/08-observability/docker-compose.observability.yml --profile analytics down"
else
  analytics_line="Analytics:  off (LLM Logs works; for the Overview dashboard re-run with --analytics)"
  stop_cmd="${COMPOSE[*]} down"
fi
cat <<EOF

================================================================
Gateway lab is up.

Console:    $console
            (or the Ports tab -> 8081 -> open in browser)
Username:   admin
EOF
if [ -n "$password" ]; then
  cat <<EOF
Password:   $password
            one-time: you choose your own at first sign-in
EOF
else
  echo "Password:   the one you chose at first sign-in"
fi
cat <<EOF
$analytics_line

Admin key and master key are saved in $ENV_FILE.
In a new terminal, load them with:   source $ENV_FILE
Stop the stack with:                 $stop_cmd
================================================================
EOF
