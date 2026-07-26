#!/bin/sh
# The single lint entry point, run locally and in CI.
#
# Usage: tools/lint.sh [check...]
#   checks: zig swift shell version forbidden testnames  (no args = all)
#
# Strict mode (CI=true, set by GitHub Actions, or LINT_STRICT=1): a
# missing tool FAILS the run. Locally a missing tool warns and skips,
# so contributors without shellcheck still get every other check.
#
# Ordering note for CI: the `zig` check needs the Zig toolchain that
# `native test --yes` installs into ~/.native/toolchains/ — run it
# AFTER the test step. Every other check works on a bare checkout.
set -eu
cd "$(dirname "$0")/.."

STRICT=0
[ "${CI:-}" = "true" ] && STRICT=1
[ "${LINT_STRICT:-}" = "1" ] && STRICT=1

FAILED=0
fail() { echo "LINT FAIL: $*" >&2; FAILED=1; }
skip_or_fail() { # tool name that's missing
    if [ "$STRICT" = "1" ]; then
        fail "$1 not available (strict mode)"
    else
        echo "lint: skipping $2 ($1 not installed locally)" >&2
    fi
}

check_zig() {
    if [ -z "${ZIG:-}" ]; then
        # Glob expands sorted, so the last executable match is the
        # newest toolchain version.
        for candidate in "$HOME"/.native/toolchains/zig-*/zig; do
            [ -x "$candidate" ] && ZIG="$candidate"
        done
    fi
    if [ -z "${ZIG:-}" ] || [ ! -x "$ZIG" ]; then
        skip_or_fail "zig toolchain (run 'native test --yes' once)" "zig fmt"
        return 0
    fi
    if ! "$ZIG" fmt --check src/ app.zon; then
        fail "zig fmt --check: files above need formatting (run: $ZIG fmt src/ app.zon)"
    else
        echo "lint ok: zig fmt"
    fi
}

check_swift() {
    if ! xcrun --find swift-format >/dev/null 2>&1; then
        skip_or_fail "swift-format (needs Xcode)" "swift lint"
        return 0
    fi
    if ! xcrun swift-format lint --strict --configuration .swift-format sidecar/*.swift; then
        fail "swift-format: fix the findings above (auto-fix: xcrun swift-format format -i --configuration .swift-format sidecar/*.swift)"
    else
        echo "lint ok: swift-format"
    fi
}

check_shell() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip_or_fail "shellcheck (brew install shellcheck)" "shellcheck"
        return 0
    fi
    if ! shellcheck tools/*.sh; then
        fail "shellcheck: fix the findings above"
    else
        echo "lint ok: shellcheck"
    fi
}

check_version() {
    # app.zon and the served OpenAPI document each carry the version;
    # they drifted once (0.6.0 vs 0.5.0) — never again.
    ZON_VERSION=$(sed -n 's/^ *\.version = "\([^"]*\)",$/\1/p' app.zon)
    API_VERSION=$(sed -n 's/^ *\\\\ *"version": "\([^"]*\)"$/\1/p' src/server.zig)
    if [ -z "$ZON_VERSION" ] || [ -z "$API_VERSION" ]; then
        fail "version check could not extract versions (app.zon: '$ZON_VERSION', server.zig: '$API_VERSION') - did the format change?"
    elif [ "$ZON_VERSION" != "$API_VERSION" ]; then
        fail "version drift: app.zon says $ZON_VERSION but src/server.zig's openapi_json says $API_VERSION - bump BOTH together"
    else
        echo "lint ok: version ($ZON_VERSION) consistent in app.zon + openapi"
    fi
}

check_forbidden() {
    # Under `set -e`, `cmd && echo "ok"` does NOT stop the script when
    # cmd fails (the left side of && is exempt) — this exact pattern
    # let 15 verify.sh checks silently pass on failure once. Write the
    # command and its echo on separate lines instead.
    HITS=$(grep -n '&& echo "ok' tools/*.sh | grep -v '^tools/lint.sh:' || true)
    if [ -n "$HITS" ]; then
        echo "$HITS" >&2
        fail "forbidden pattern '&& echo \"ok' in tools/*.sh (silently passes on failure under set -e)"
    else
        echo "lint ok: no silent-pass patterns in tools/"
    fi
}

check_testnames() {
    # Convention: test names are lowercase descriptive sentences.
    HITS=$(grep -n '^test "[A-Z]' src/tests.zig || true)
    if [ -n "$HITS" ]; then
        echo "$HITS" >&2
        fail "test names start lowercase (descriptive sentences), e.g. test \"the queue drains in order\""
    else
        echo "lint ok: test names follow the lowercase-sentence convention"
    fi
}

CHECKS="${*:-zig swift shell version forbidden testnames}"
for check in $CHECKS; do
    case "$check" in
        zig) check_zig ;;
        swift) check_swift ;;
        shell) check_shell ;;
        version) check_version ;;
        forbidden) check_forbidden ;;
        testnames) check_testnames ;;
        *) fail "unknown check: $check (valid: zig swift shell version forbidden testnames)" ;;
    esac
done

[ "$FAILED" = "0" ] || exit 1
echo "lint: all requested checks passed"
