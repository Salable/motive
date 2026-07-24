# REST Control Plane

A loopback (`127.0.0.1`) HTTP server exposing the `MotiveControl` command
surface, provided by the `MotiveHTTP` product. Every documented verb is
honored by the renderer; nothing here is aspirational.

## Discovery and auth

- `~/.motive/runtime/server.json` records the bound port, host, pid, and
  version (`MOTIVE_HOME` overrides the base directory). The preferred port is
  7877; collisions fall back to an ephemeral port, and `server.json` records
  the truth.
- Auth: a per-boot token written to `~/.motive/runtime/token` (mode 0600),
  rotated on every server start. Send it as `Authorization: Bearer <token>`
  or `X-Motive-Token`. Only `GET /v1/ping` is unauthenticated.
- Hardening: constant-time token compare, request rate limiting, 64 KB body
  cap. The server may also be bound to `0.0.0.0` (token auth unchanged) for
  driving a pet from another machine.

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"state": "jumping"}' "http://127.0.0.1:$PORT/v1/state"
```

`scripts/demo-curl.sh` walks the whole surface against a running demo.

## Endpoints

| Endpoint | Effect |
| --- | --- |
| `GET /v1/ping` | Liveness (unauthenticated). |
| `GET /v1/schema` | Self-describing: the loaded sprite's states, triggers, and verbs, with `purpose` prose for agents. |
| `GET /v1/status` | Name, version, current state, speech bubble, queue depth. |
| `GET /v1/events` | Server-sent events stream (below). |
| `POST /v1/state` | `{"state", "duration"?}` — change state; `duration` (ms) auto-reverts. |
| `POST /v1/trigger` | `{"name"}` — one-shot gesture, then return to the prior state. |
| `POST /v1/say` | `{"text", "ttl"?}` — speech bubble (≤ 400 chars; `ttl` ms). |
| `DELETE /v1/speech` | Dismiss the current bubble. |
| `POST /v1/queue` | `{"items": […]}` — append to the action queue (tail). |
| `GET /v1/queue` | Inspect: depth, current item + remaining hold, pending items. |
| `DELETE /v1/queue` | Flush the queue. |
| `POST /v1/script` | Compat sugar: **replace** the queue with these steps (v0.1.0 wire shape). |
| `DELETE /v1/script` | Same as `DELETE /v1/queue`. |

## Queue semantics

Every action is a queue item processed in order. The direct verbs
(`/v1/state`, `/v1/trigger`, `/v1/say`) **head-enqueue**: they play *next*,
cutting the current item's remaining hold; everything already queued continues
afterwards. Nothing is dropped except by an explicit flush.

`POST /v1/queue` items look like:

```json
{"items": [
  {"type": "say", "text": "hi", "hold": 3000},
  {"type": "trigger", "name": "jump"},
  {"type": "pause", "ms": 1000},
  {"type": "setState", "name": "idle"}
]}
```

Validation is all-or-nothing; total depth is capped at 64. Per-item `hold`
defaults: `say` 4000 ms (== bubble time), `setState` 0, `trigger` = the
gesture's length.

## Events

`GET /v1/events` emits named SSE frames:

- `event: state` — `{"state": …}` on every state change.
- `event: speech` / `event: speech-dismissed` — bubble lifecycle.
- `event: queue` — `{"phase": "item-started" | "item-finished" | "drained" | "flushed", …}`
  with item id, remaining hold, or dropped count as applicable.

## Errors

Failures return `{"ok": false, "error": …}` and, for vocabulary mistakes
(unknown state/trigger, bad item type), a `valid` array naming the accepted
values — agents can self-correct from the response alone.
