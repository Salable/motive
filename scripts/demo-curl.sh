#!/usr/bin/env bash
# Drive a running motive-demo through its REST control plane.
set -euo pipefail

RUNTIME="${MOTIVE_HOME:-$HOME/.motive}/runtime"
TOKEN_FILE="$RUNTIME/token"
SERVER_FILE="$RUNTIME/server.json"

if [[ ! -f "$TOKEN_FILE" || ! -f "$SERVER_FILE" ]]; then
  echo "No running Motive app found (missing $RUNTIME/{token,server.json})." >&2
  echo "Start one first: swift run motive-demo" >&2
  exit 1
fi

TOKEN="$(cat "$TOKEN_FILE")"
PORT="$(python3 -c "import json;print(json.load(open('$SERVER_FILE'))['port'])")"
BASE="http://127.0.0.1:$PORT"
auth=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

step() { printf '\n== %s\n' "$1"; }

step "ping (unauthenticated)"
curl -sf "$BASE/v1/ping"; echo

step "schema"
curl -sf "${auth[@]}" "$BASE/v1/schema" | python3 -m json.tool | head -30

step "status"
curl -sf "${auth[@]}" "$BASE/v1/status"; echo

step "say hello"
curl -sf "${auth[@]}" -d '{"text":"Hello from curl!"}' "$BASE/v1/say"; echo

step "state -> running (for 3s, then auto-revert)"
curl -sf "${auth[@]}" -d '{"state":"running","duration":3000}' "$BASE/v1/state"; echo

step "trigger jump"
curl -sf "${auth[@]}" -d '{"name":"jump"}' "$BASE/v1/trigger"; echo

echo
echo "Done — watch the sprite react. Stream events with:"
echo "  curl -N ${auth[0]} \"${auth[1]}\" $BASE/v1/events"
