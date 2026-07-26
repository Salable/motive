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
| `POST /v1/say` | `{"text", "ttl"?, "respond"?}` — speech bubble (≤ 400 chars; `ttl` ms). With `respond`, a question (below). |
| `DELETE /v1/speech` | Dismiss the current bubble. |
| `POST /v1/queue` | `{"items": […]}` — append to the action queue (tail). |
| `GET /v1/queue` | Inspect: depth, current item + remaining hold, pending items. |
| `DELETE /v1/queue` | Flush the queue and return to the default state. |
| `DELETE /v1/queue/current` | Skip the current item: it ends now, the next pending item plays. Pending preserved. |
| `POST /v1/script` | Compat sugar: **replace** the queue with these steps (v0.1.0 wire shape). |
| `DELETE /v1/script` | Same as `DELETE /v1/queue`. |
| `GET /v1/questions` | `?id`, `?wait` (ms, ≤ 30000) — open questions; long-poll for an answer. |
| `DELETE /v1/questions` | `{"id"?}` — withdraw a question (all open ones when `id` is omitted). |
| `GET /v1/questions/history` | `?limit` — past questions and answers, newest first. |
| `DELETE /v1/questions/history` | `{"keep"?}` — cull stored history. |

## Queue semantics

Every action is a queue item processed in order. The direct verbs
(`/v1/state`, `/v1/trigger`, `/v1/say`) **head-enqueue**: they play *next*,
cutting the current item's remaining hold; everything already queued continues
afterwards. Nothing is dropped except by an explicit flush.

One exception: a **question** cannot have its hold cut, because it has no hold —
it waits on a human. A direct verb issued while a question is outstanding is
deferred behind it, not dropped, and plays as soon as the question resolves.

## Questions

`POST /v1/say` takes an optional `respond` object that turns the bubble into a
question the pet blocks on:

```json
{"text": "Deploy to production?",
 "respond": {"form": "confirm", "timeout": 300000}}
```

- `form` — `confirm` (yes/no), `choice` (`choices`: 2–6 options), `text`
  (`placeholder`). Unknown forms return 400 with the valid list.
- `timeout` — milliseconds until the question expires. Optional but strongly
  recommended; clamped to one hour. We impose no deadline of our own: an
  unanswered question waits indefinitely, so the asker owns its own patience.
- `ttl` is ignored — the bubble lives until the question resolves.

The receipt carries `questionID`. Poll it:

```
GET /v1/questions?id=<id>&wait=15000
```

`wait` parks the request until the question resolves or the budget elapses. A
timed-out poll is a **200** with `"status": "awaiting"` — never an error — so
the caller's loop is a plain `while status == "awaiting"`.

| `status` | meaning |
| --- | --- |
| `awaiting` | not answered yet |
| `accepted` | answered; `answer` holds it |
| `declined` | the human explicitly refused to answer |
| `cancelled` | dismissed by the human, or withdrawn by the asker |
| `expired` | the asker's `timeout` elapsed |

For `confirm`, both buttons are `accepted` — read `answer.confirmed`. "No" is an
answer, not a refusal.

**Answers originate only from UI input.** There is deliberately no endpoint that
resolves a question as answered: a local process holding the token could
otherwise forge a human's answer, and the human-in-the-loop guarantee would mean
nothing. Agents can ask, read, and withdraw — not answer.

Questions block at the head of the queue; a second question waits behind the
first. A human may answer a *pending* question out of order, which resolves it
in place without disturbing the one on screen.

### History

Resolved questions and their answers persist to
`$MOTIVE_HOME/history/questions.jsonl` (default `~/.motive/history/`), owner-only,
and survive restarts — deliberately a sibling of `runtime/`, whose contents are
deleted on shutdown. Read it with `GET /v1/questions/history?limit=N`; cull it
with `DELETE /v1/questions/history` (`{"keep": N}` to retain the newest N), or
from Settings → Questions in a host app that exposes it.

An agent that missed an SSE event, or that started after an answer landed, reads
history rather than re-asking.

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

**Skip** (`DELETE /v1/queue/current`) is the single-item counterpart of flush:
the current item ends immediately and the next pending item plays. It doesn't
rewind on-screen state (a skipped trigger's gesture completes on its own),
except a skipped `say`'s bubble is dismissed. The receipt carries `skippedID`;
skipping an idle queue is an ok no-op.

**Clear** (`DELETE /v1/queue`) returns the sprite to its **default state** —
the engine's initial state (`idle` in the demo). Stopping a scene never leaves
the sprite stuck in a state that a dropped item would have cleaned up. States
set directly (`POST /v1/state`, no duration) persist until changed — natural
queue drain does not force a revert, so an agent's `working` mood survives its
own says and gestures; scenes that end themselves choose their final state.

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
