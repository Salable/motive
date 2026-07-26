#!/bin/sh
# Build the TTS speaker sidecar the app spawns via fx.spawn.
# Output: zig-out/sidecar/speaker-sidecar
set -eu
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found (install Xcode Command Line Tools)" >&2
    exit 1
}
mkdir -p zig-out/sidecar
swiftc -O -o zig-out/sidecar/speaker-sidecar sidecar/speaker.swift
echo "built zig-out/sidecar/speaker-sidecar"
