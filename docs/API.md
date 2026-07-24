# REST Control Plane

Lands in milestone M3. A loopback (`127.0.0.1`) HTTP server exposing the `MotiveControl`
command surface.

- Auth: per-boot token written to `~/.motive/runtime/token` (mode 0600); send as
  `Authorization: Bearer <token>` or `X-Motive-Token`. `GET /v1/ping` is unauthenticated.
- Discovery: `~/.motive/runtime/server.json` records the bound port.
- `GET /v1/schema` — self-describing: states, triggers, and verbs of the loaded sprite.
- `GET /v1/events` — server-sent events stream.
- `POST /v1/state` · `POST /v1/trigger` · `POST /v1/say` — drive the sprite.

Every documented verb is honored by the renderer; nothing here is aspirational.
