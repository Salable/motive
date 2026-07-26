# Releasing

> **Audience:** maintainers.
> **Prerequisites:** push access and the ability to tag.
> **Source of truth:** `.github/workflows/release.yml`, `scripts/build-demo-app.sh`, `MotiveVersion.current`.

Motive follows [Semantic Versioning](https://semver.org/) and keeps
[CHANGELOG.md](../CHANGELOG.md) in [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
format. During `0.x`, minor versions may break API.

## Cutting a release

1. **Update the changelog.** Move the `[Unreleased]` items into a new
   `## [X.Y.Z] - YYYY-MM-DD` section.
2. **Bump the version constant** in
   [`Sources/MotiveCore/MotiveVersion.swift`](../Sources/MotiveCore/MotiveVersion.swift)
   (`MotiveVersion.current`). This is the single source of truth: the control
   plane reports it in `/v1/status` and `server.json`, and the packaging
   script names the zip from it **and stamps it into the app bundle's
   `Info.plist`**. The committed `Resources/Info.plist` carries the same
   number — a test (`testBundlePlistMatchesVersionConstant`) fails until you
   bump both.
3. **Commit and merge to `main`** (subject `Release X.Y.Z`), with CI green
   (`swift test` on macOS).
4. **Tag and push:**

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

5. The [release workflow](../.github/workflows/release.yml) runs the tests,
   builds a universal (arm64 + x86_64) `MotiveDemo.app`, and attaches
   `MotiveDemo-X.Y.Z.zip` to the GitHub release with generated notes. Verify
   the asset is attached and skim the notes.

## The demo app bundle

[`scripts/build-demo-app.sh`](../scripts/build-demo-app.sh) produces
`dist/MotiveDemo.app`:

```sh
scripts/build-demo-app.sh               # host arch
scripts/build-demo-app.sh --universal   # arm64 + x86_64 (what CI ships)
scripts/build-demo-app.sh --zip         # also dist/MotiveDemo-<version>.zip
```

The bundle embeds the Winston sprite package and the `motive-mcp` shim
(`Contents/MacOS/motive-mcp`) so downloaders can register the MCP server
without a checkout. `Resources/AppIcon.icns` is committed; the script only
regenerates it (via `scripts/make-icon.py`, needs Pillow) when it's missing.

The README's Winston GIFs (`docs/images/`) are committed too, and are not part
of any build: rerun `scripts/make-readme-art.py` (needs Pillow) manually
whenever the Winston atlas or `motive.json` changes — it is deterministic, so an
unchanged sprite produces byte-identical files.

Signing is ad-hoc by default — downloaders right-click → Open, or
`xattr -cr MotiveDemo.app`. Set `MOTIVE_SIGN_IDENTITY` to a Developer ID for
distribution-grade signing; the app is not yet notarized.

## SwiftPM consumers

Consumers pin the package by tag (`from: "X.Y.Z"`), so a pushed tag *is* the
library release — nothing else to publish. Don't move or delete published
tags.
