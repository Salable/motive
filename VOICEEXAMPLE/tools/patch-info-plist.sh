#!/bin/sh
# Adds the two Info.plist usage-description keys the voice-reply path
# needs. Run this AFTER `native package` and BEFORE launching the
# packaged app.
#
# Why this exists: `native package` does not emit these keys today (the
# SDK's macosInfoPlist() writes a fixed key set and never reads
# app.zon's `.permissions`), and macOS does not gracefully deny a
# process that lacks them when it touches AVAudioApplication/
# SFSpeechRecognizer — it KILLS it (confirmed directly: listener-
# sidecar crashed with TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION the
# instant it requested mic access unpackaged). A patched .app is the
# only way to get a real permission PROMPT instead of a silent kill.
#
# Usage: tools/patch-info-plist.sh [path/to/TalkBox.app]
#   (with no argument, the first .app under zig-out/package/ is used)
set -eu
cd "$(dirname "$0")/.."

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find zig-out/package -maxdepth 1 -name '*.app' 2>/dev/null | head -1)
fi
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "error: no packaged .app found - run 'native package' first, or pass its path" >&2
    exit 1
fi

PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "error: $PLIST not found - is $APP_PATH a valid app bundle?" >&2
    exit 1
fi

add_key() {
    key="$1"; value="$2"
    /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST"
}

add_key NSMicrophoneUsageDescription "TalkBox uses the microphone so you can speak a reply instead of typing it."
add_key NSSpeechRecognitionUsageDescription "TalkBox transcribes your spoken reply on-device using Speech Recognition."

echo "patched $PLIST"
echo "re-sign after patching a signed bundle: codesign --force --deep -s - \"$APP_PATH\""
