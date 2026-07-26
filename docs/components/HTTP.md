# MotiveHTTP

> **Audience:** embedders exposing a control plane. For the client side, read [../API.md](../API.md).
> **Prerequisites:** [../concepts/RUNTIME.md](../concepts/RUNTIME.md).
> **Source of truth:** `Sources/MotiveHTTP/MotiveServer.swift`; 43 tests in `Tests/MotiveHTTPTests/`.

A loopback REST server over `MotiveControl`, built on SwiftNIO. It is the one
product with an external dependency, and the only one that opens a socket.

```swift
import MotiveHTTP

let control = MotiveControl(engine: host.engine, displayName: "Winston")
let server = MotiveServer(control: control)
let info = try await server.start()
print("http://\(info.host):\(info.port)")
```

Two lines to give a pet an API. The routes add no semantics of their own — they
are 1:1 adapters over `MotiveControl`, which is why `/v1/schema` can describe
them truthfully without a hand-maintained spec.

## `MotiveServer`

```swift
public init(
    control: MotiveControl,
    paths: RuntimePaths = .standard,
    preferredPort: Int = MotiveServer.defaultPort,   // 7877
    bindHost: String = "127.0.0.1",
    rateLimiter: RateLimiter = RateLimiter()          // 30/s, burst 60
)
```

| Parameter | Default | Notes |
| --- | --- | --- |
| `control` | — | The command surface. One per pet. |
| `paths` | `.standard` | Honors `MOTIVE_HOME`. Where `server.json` and `token` land. |
| `preferredPort` | 7877 | *Preferred.* A collision falls back to an ephemeral port and `server.json` records the truth. |
| `bindHost` | `127.0.0.1` | `0.0.0.0` to accept connections from your network; token auth is unchanged. |
| `rateLimiter` | 30/s, burst 60 | Shared across all clients, not per-client. |

```swift
@discardableResult public func start() async throws -> ServerInfo
public func stop() async
```

`start()` creates `runtime/` (0700), rotates the bearer token, binds, and writes
`server.json` — returning the `ServerInfo` with the port actually bound. Throws
`MotiveServerError.noLocalPort` if it cannot bind at all.

`stop()` deletes both runtime files and shuts the event-loop group down.

**`stop()` is terminal.** A stopped `MotiveServer` cannot rebind, because its
event-loop group is gone. Changing the port or bind host means constructing a
fresh instance:

```swift
if let old = server { server = nil; await old.stop() }
server = MotiveServer(control: control, preferredPort: newPort, bindHost: newHost)
try await server?.start()
```

The demo debounces this by 500 ms, latest-wins, so typing a port number does not
thrash. Note that a restart **rotates the token** — anything holding the old one
must re-read it.

Stop the server on quit, or you leave a `server.json` pointing at a dead port:

```swift
func applicationWillTerminate(_ notification: Notification) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { [server] in await server?.stop(); semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 2)
}
```

## Routes

Twelve endpoints across `GET`, `POST`, and `DELETE`. Full semantics, request
shapes, and error codes are in [../API.md](../API.md); the short version:

`GET` — `/v1/ping` (unauthenticated), `/v1/schema`, `/v1/status`, `/v1/events`
(SSE), `/v1/queue`, `/v1/questions`, `/v1/questions/history`, `/v1/activity`.

`POST` — `/v1/state`, `/v1/trigger`, `/v1/say`, `/v1/queue`, `/v1/queue/pause`,
`/v1/queue/resume`, `/v1/script`.

`DELETE` — `/v1/speech`, `/v1/queue`, `/v1/queue/current`, `/v1/questions`,
`/v1/activity`, `/v1/script`.

There is deliberately no route that answers a question.

## Hardening

| | |
| --- | --- |
| Bind | Loopback by default; public is opt-in and explicit. |
| Auth | Per-boot 256-bit token, mode 0600, rotated every start. `Authorization: Bearer` or `X-Motive-Token`. |
| Compare | Constant-time (`TokenManager.constantTimeEquals`). |
| Body cap | 64 KB → `payload_too_large`. |
| Rate limit | Token bucket, 30/s burst 60 → `rate_limited`. |
| Unauthenticated | `GET /v1/ping` only, so a client can check liveness before it has a credential. |

The honest limit: the token authenticates the *machine*, not the caller. Any
local process that can read your home directory can drive your pet. That is
acceptable for a desktop companion — and it is precisely why nothing here can
answer a question on a human's behalf.

## Errors

Failures return `{"ok": false, "error": …}`. Vocabulary mistakes carry a `valid`
array naming the accepted values, so a caller can self-correct from the response
alone. Codes include `unknown_state`, `unknown_trigger`, `unknown_question`,
`invalid_items`, `invalid_steps`, `invalid_respond`, `invalid_json`,
`missing_text`, `payload_too_large`, `rate_limited`, `not_found`.

## SSE

`GET /v1/events` streams named frames — `state`, `speech`, `speech-dismissed`,
`queue` — serialized from the engine's event stream.

There is **no replay**. A client that disconnects misses what happened while it
was away. For "what did I miss", use `GET /v1/activity?since=<seq>`, whose
sequence numbers are monotonic, durable, and survive restarts. Reach for SSE when
you want to react promptly, and for activity when you need to be correct.

## Testing against it

`Tests/MotiveHTTPTests/MotiveServerTests.swift` starts real servers on ephemeral
ports against a scratch `RuntimePaths` — copy the pattern rather than mocking:

```swift
let paths = RuntimePaths(rootURL: tempDir)
let server = MotiveServer(control: control, paths: paths, preferredPort: 0)
let info = try await server.start()
defer { Task { await server.stop() } }
```

`MotiveMCPTests` does the same to exercise `RESTCommandTransport` end to end.
