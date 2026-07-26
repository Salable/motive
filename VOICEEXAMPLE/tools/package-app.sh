#!/bin/sh
# Build a complete, launchable TalkBox.app. This is THE way to package
# — calling `native package` directly has two footguns this script
# exists to close:
#   1. `native package` does NOT rebuild; it silently bundles whatever
#      stale binary zig-out/bin already holds. (Learned the hard way:
#      a day-old binary shipped the pre-reply-feature design.)
#   2. The bundle needs pieces `native package` doesn't know about:
#      the two Swift sidecars (beside the main executable, where the
#      app's bundle-mode path resolution expects them) and the
#      mic/speech-recognition Info.plist keys for voice replies.
#
# Usage: tools/package-app.sh
#   SIGNING=adhoc (default) — set SIGNING=none to skip signing.
set -eu
cd "$(dirname "$0")/.."
SIGNING="${SIGNING:-adhoc}"

echo "==> sidecars (swiftc)"
tools/build-speaker.sh
tools/build-listener.sh

echo "==> fresh app binary (native build, ReleaseFast)"
native build --yes

echo "==> bundle (native package)"
native package --signing "$SIGNING"
APP_PATH=$(find zig-out/package -maxdepth 1 -name '*.app' | head -1)
[ -n "$APP_PATH" ] || { echo "error: native package produced no .app" >&2; exit 1; }

echo "==> sidecars into the bundle"
cp zig-out/sidecar/speaker-sidecar zig-out/sidecar/listener-sidecar "$APP_PATH/Contents/MacOS/"

echo "==> Info.plist mic/speech keys"
tools/patch-info-plist.sh "$APP_PATH"

if [ "$SIGNING" != "none" ]; then
    echo "==> re-sign (the copies + plist edit invalidated the package signature)"
    codesign --force --deep -s - "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
fi

echo "==> done: $APP_PATH"
