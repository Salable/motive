# Apps

> **Audience:** anyone assembling a companion from the kit.
> **Prerequisites:** [../docs/guides/ASSEMBLE-AN-APP.md](../docs/guides/ASSEMBLE-AN-APP.md) is the walkthrough this directory exists for.
> **Source of truth:** `.gitignore` — everything here except this file is ignored.

Assembled companion apps land here. **Nothing in this directory is committed**
except this README: `.gitignore` carries `Apps/*` with an exception for it, so a
local build never shows up in a diff and nobody has to keep someone else's
scratch app compiling.

Motive ships exactly one app, `motive-demo`, and it lives in `Sources/MotiveDemo`
with the rest of the package. Everything you assemble out of
[../Kit/](../Kit/) is yours, and it is built the way anyone outside this
repository would build it:

```swift
// Apps/MyCompanion/Package.swift
dependencies: [
    .package(url: "https://github.com/Salable/motive.git", from: "0.4.0"),
],
```

A path dependency back into this checkout would be easier and would prove
nothing — an app that only builds inside the repository is not evidence that
anyone else can build one. So an assembled app is a standalone SwiftPM package
with its own `Sources/`, its own copy of the sprite, and no reference to
anything above its own directory. You can move it out of here at any point and
it keeps working.

## Working against unreleased framework changes

The published release is the default. When you need the app to build against
your working copy — a framework change that is not tagged yet — override the
dependency rather than editing `Package.swift`:

```sh
cd Apps/MyCompanion
swift package edit Motive --path /path/to/motive     # use the local checkout
swift build && swift run MyCompanion
swift package unedit Motive                          # back to the release
```

`swift package edit` leaves the manifest alone, so what you ship is still what a
stranger would resolve.

## Running and packaging

```sh
cd Apps/MyCompanion
swift build && swift run MyCompanion
MOTIVE_HOME=$(pwd)/.motive-home swift run MyCompanion   # side by side with the demo
```

Two companions on one machine will fight over the runtime home and the control
plane's port, so give each one its own `MOTIVE_HOME`
([../docs/concepts/RUNTIME.md](../docs/concepts/RUNTIME.md)).

Turning it into a `.app` is
[../docs/EMBEDDING.md#ship-an-app-bundle](../docs/EMBEDDING.md#ship-an-app-bundle);
`../scripts/build-demo-app.sh` is the working example to copy.
