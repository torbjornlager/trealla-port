#!/bin/sh

# SPDX-License-Identifier: MIT

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE=$ROOT/Deployment/compose.yaml
SMOKE_DIR=$(mktemp -d /tmp/trealla-deployment-smoke.XXXXXX)
ENV_FILE=$SMOKE_DIR/smoke.env
PROJECT=trealla_port_smoke_$$
PASSWORD=trealla-pilot-smoke
ADMIN_TOKEN=smoke-admin-token-0000000000000000

cleanup() {
    docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
        down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT HUP INT TERM

command -v docker >/dev/null 2>&1 || {
    printf '%s\n' 'docker is required for the deployment smoke test' >&2
    exit 2
}

HASH=$(docker run --rm caddy:2.8.4-alpine \
    caddy hash-password --plaintext "$PASSWORD")

cat >"$ENV_FILE" <<EOF
SITE_ADDRESS=http://localhost:8080
PUBLIC_NODE_URL=http://localhost:8080
BROWSER_ORIGIN=http://localhost:8080
PILOT_USER=pilot
PILOT_PASSWORD_HASH='$HASH'
WP_ADMIN_TOKEN=$ADMIN_TOKEN
WP_DRAIN_GRACE_SECONDS=1
PILOT_PORT=18080
HTTP_PORT=18081
HTTPS_PORT=18443
EOF

docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
    up --detach --build --wait

docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
    exec -T trealla test -f /usr/share/doc/trealla/LICENSE
docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
    exec -T trealla test -f /usr/share/doc/trealla/ATTRIBUTION
docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
    exec -T caddy test -f /usr/share/licenses/caddy/LICENSE

BASE=http://localhost:18080
CURL_AUTH=pilot:$PASSWORD

status=$(curl --silent --output /dev/null --write-out '%{http_code}' "$BASE/healthz")
[ "$status" = 401 ]

health=$(curl --fail --silent --show-error --user "$CURL_AUTH" "$BASE/healthz")
[ "$health" = '{"status":"ok"}' ]

status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "$CURL_AUTH" "$BASE/admin/runtime")
[ "$status" = 404 ]

ready=$(curl --fail --silent --show-error --user "$CURL_AUTH" "$BASE/readyz")
[ "$ready" = '{"status":"ready"}' ]

info=$(curl --fail --silent --show-error --user "$CURL_AUTH" "$BASE/node_info")
printf '%s' "$info" | grep -Fq '"self_url":"http:\/\/localhost:8080"'
printf '%s' "$info" | grep -Fq '"profile":"actor"'
printf '%s' "$info" | grep -Fq '"sandbox":"whitelist"'

answer=$(curl --fail --silent --show-error --user "$CURL_AUTH" \
    "$BASE/call?goal=member(X%2C%5Ba%2Cb%5D)&format=json&limit=1")
printf '%s' "$answer" | grep -q '"type":"success"'
printf '%s' "$answer" | grep -q '"X":"a"'

ws_headers=$SMOKE_DIR/websocket-headers
curl --silent --show-error --include --no-buffer --max-time 1 \
    --user "$CURL_AUTH" \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$BASE/ws" >"$ws_headers" 2>/dev/null || true
grep -Eq '^HTTP/1\.[01] 101 ' "$ws_headers"
grep -Eiq '^Upgrade: websocket' "$ws_headers"

docker compose -p "$PROJECT" -f "$COMPOSE" --env-file "$ENV_FILE" \
    exec -T trealla /opt/trealla/tpl -g \
    "use_module('/app/Deployment/start_node.pl'),deployment_start:request_maintenance,halt"

status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "$CURL_AUTH" "$BASE/readyz")
[ "$status" = 503 ]

printf '%s\n' 'Trealla deployment smoke test: ok'
