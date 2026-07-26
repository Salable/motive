#!/bin/sh
# Build the reply-listening sidecar the app spawns (ephemerally, one
# per recording attempt) via fx.spawn.
# Output: zig-out/sidecar/listener-sidecar
set -eu
cd "$(dirname "$0")/.."
command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found (install Xcode Command Line Tools)" >&2
    exit 1
}
mkdir -p zig-out/sidecar
swiftc -O -o zig-out/sidecar/listener-sidecar sidecar/listener.swift
echo "built zig-out/sidecar/listener-sidecar"
