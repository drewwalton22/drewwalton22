#!/usr/bin/env bash
# Offline check for the Shared modules (no Roblox Studio needed).
#
# Roblox modules use `require(script.Parent.X)`, which standalone Luau can't
# resolve. This script copies Shared/ to a temp dir, rewrites those requires to
# `require("./X")`, then runs `luau-analyze` (strict type check) and executes
# tools/verify_shared.luau.
#
# Usage: LUAU_BIN=/path/to/dir/with/luau-and-luau-analyze tools/check.sh
#        (or put `luau` and `luau-analyze` on PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/src/ReplicatedStorage/GolfRivals/Shared"
BIN="${LUAU_BIN:-}"
LUAU="${BIN:+$BIN/}luau"
ANALYZE="${BIN:+$BIN/}luau-analyze"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in "$SHARED"/*.luau; do
	sed -E 's/require\(script\.Parent\.([A-Za-z0-9_]+)\)/require(".\/\1")/g' "$f" > "$TMP/$(basename "$f")"
done
cp "$ROOT/tools/verify_shared.luau" "$TMP/verify_shared.luau"

echo "== luau-analyze (strict) =="
"$ANALYZE" "$TMP"/*.luau
echo "analyze: clean"

echo "== run verification =="
"$LUAU" "$TMP/verify_shared.luau"
