# The Runtime Home

> **Audience:** anyone connecting to a companion from outside it, and anyone running more than one.
> **Prerequisites:** none.
> **Source of truth:** `Sources/MotiveCore/RuntimeDiscovery.swift`.

A Motive app has no fixed address. It binds a port that may not be the one it
asked for, and it mints a fresh credential every time it starts. So there has to
be somewhere to *look*, and that place is the runtime home.

```
~/.motive/                     ($MOTIVE_HOME overrides this root, 0700)
├── runtime/                   ephemeral — deleted on clean shutdown
│   ├── server.json            {port, pid, version, startedAt, name, host}   0600
│   └── token                  256-bit hex bearer token                      0600
└── history/                   durable — survives shutdown
    └── activity.jsonl         the activity log, including question answers  0600
```

## The two-file handshake

Discovery is deliberately boring: read `server.json` for the port, read `token`
for the credential, make an HTTP request. No broadcast, no registry, no daemon.
Anything that can read a file and make a request can drive a companion — `curl`, a
shell script, an agent skill, the `motive-mcp` shim.

```sh
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
TOKEN=$(cat ~/.motive/runtime/token)
```

**Read the port; do not assume it.** 7877 is only *preferred*. A collision falls
back to an ephemeral port and `server.json` records the truth, which is the whole
reason the file exists.

**Re-read the token.** It is regenerated on every server start — including
restarts triggered by changing a Control Plane setting. A stale token is a 401,
and a connect prompt pasted into an agent yesterday is a connect prompt that no
longer works.

## Why the token rotates

The alternative is a long-lived secret sitting in a file, and there is no
lifecycle in which that is better. A per-boot token means a leaked one is dead
the moment the app restarts, and it makes the failure mode loud (401) rather than
silent.

Auth is a bearer token over loopback, sent as `Authorization: Bearer <token>` or
`X-Motive-Token`. Comparison is constant-time. Only `GET /v1/ping` is
unauthenticated, so a client can check liveness before it has a credential.

The honest limit of this model: **the token authenticates the machine, not the
caller.** Any local process that can read your home directory can drive your companion.
That is acceptable for a desktop companion, and it is exactly why nothing on the
control plane can [answer a question](QUESTIONS.md#the-one-rule).

## Ephemeral versus durable

`runtime/` and `history/` are siblings, and the nesting is load-bearing.
`MotiveServer.stop()` deletes the two files it wrote under `runtime/` — a
lingering `server.json` pointing at a dead port is worse than no file at all.
Anything that must survive that lives outside the directory being swept.

So: the activity log, question history, and answers persist. Outstanding
questions do not — see [QUESTIONS.md](QUESTIONS.md#polling).

A `server.json` whose `pid` no longer exists is a leftover from a hard kill.
Clients should tolerate one rather than trusting it blindly.

## Binding publicly

The server can bind `0.0.0.0` instead of `127.0.0.1`, and `server.json` records
which. Token auth is unchanged and still required for every request.

This is for driving a companion from another machine — a build server pointing at the
laptop on your desk. macOS will likely ask to allow incoming connections. The
connect prompt notices the public bind and tells the agent that you will supply
the machine's address, since `server.json` cannot know what other hosts call
this one.

## `MOTIVE_HOME`

Everything honors it: the app, the `motive-mcp` shim, the generated agent skills,
`scripts/demo-curl.sh`. Point two instances at two homes and they cannot collide.

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

This is the supported way to run companions side by side — one per worktree while
developing, or a stable companion plus a scratch one. Port collisions resolve
themselves; it is the *files* that need separating.

It is also how tests stay out of your real `~/.motive`, and why
`RuntimePaths.standard` reads the environment rather than hard-coding a path.

A caveat worth knowing: an agent configured while one home was active keeps
looking at that home. The `motive-mcp` shim reads `MOTIVE_HOME` from its own
environment, which is the MCP host's environment, not yours.

## In code

```swift
let paths = RuntimePaths.standard              // honors MOTIVE_HOME
let paths = RuntimePaths(rootURL: scratchDir)  // explicit, for tests

try paths.prepare()          // create runtime/, 0700
try paths.prepareHistory()   // create history/, 0700

let info = try ServerInfo.load(from: paths.serverInfoURL)
let token = try TokenManager.load(at: paths.tokenURL)
```

`MotiveServer` does all of this for you; you need it directly only when writing a
client. `TokenManager.rotate(at:)` mints and installs a new token,
`TokenManager.constantTimeEquals` is the comparison to use if you are validating
one yourself.

Full variable list: [../reference/ENVIRONMENT.md](../reference/ENVIRONMENT.md).
