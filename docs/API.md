# REST Control Plane

Lands in milestone M3. A loopback (`127.0.0.1`) HTTP server exposing the `MotiveControl`
command surface.

- Auth: per-boot token written to `~/.motive/runtime/token` (mode 0600); send as
  `Authorization: Bearer <token>` or `X-Motive-Token`. `GET /v1/ping` is unauthenticated.
- Discovery: `~/.motive/runtime/server.json` records the bound port.
- `GET /v1/schema` — self-describing: states, triggers, and verbs of the loaded sprite.
- `GET /v1/events` — server-sent events stream.
- `POST /v1/state` · `POST /v1/trigger` · `POST /v1/say` — direct verbs. These
  **head-enqueue**: they play next (cutting the current item's remaining hold), and
  everything already queued continues afterwards — nothing is dropped.
- `POST /v1/queue` — append items to the action queue (tail), e.g.
  `{"items": [{"type": "say", "text": "hi", "hold": 3000}, {"type": "trigger", "name": "jump"}, {"type": "pause", "ms": 1000}, {"type": "setState", "name": "idle"}]}`.
  All-or-nothing validation; ≤64 total depth; per-item `hold` defaults: say 4000 ms
  (== bubble time), setState 0, trigger = the gesture's length. `GET /v1/queue`
  inspects (depth, current item + remaining, pending); `DELETE /v1/queue` flushes.
- `POST /v1/script` — compat sugar: replace the queue with these steps
  (`DELETE /v1/script` = flush). SSE emits `event: queue` frames for
  item-started/item-finished/drained/flushed.

Every documented verb is honored by the renderer; nothing here is aspirational.
