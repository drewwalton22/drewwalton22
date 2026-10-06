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
COMPILE="${BIN:+$BIN/}luau-compile"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Server modules reach Shared through `Shared.X` (statically resolvable in Studio)
# and mark their Roblox-only lookup lines with OFFLINE-STRIP. For the offline
# copy we delete those lines and turn every require into a sibling path.
#
# Files tagged "ROBLOX-ONLY" touch game/Instance APIs: they cannot be analyzed or
# run standalone, so they only get a syntax check (luau-compile) below.
SERVER="$ROOT/src/ServerScriptService/GolfRivals/Server"
PURE=()
ROBLOX_ONLY=()
for f in "$SHARED"/*.luau "$SERVER"/*.luau; do
	out="$TMP/$(basename "$f")"
	sed -E \
		-e '/OFFLINE-STRIP/d' \
		-e 's/require\(script\.Parent\.([A-Za-z0-9_]+)\)/require(".\/\1")/g' \
		-e 's/require\(Shared\.([A-Za-z0-9_]+)\)/require(".\/\1")/g' \
		"$f" > "$out"
	if grep -q "ROBLOX-ONLY" "$f"; then ROBLOX_ONLY+=("$out"); else PURE+=("$out"); fi
done
cp "$ROOT/tools/verify_shared.luau" "$TMP/verify_shared.luau"

echo "== luau-analyze (strict) on ${#PURE[@]} pure modules =="
ANALYZE_OUT="$("$ANALYZE" "${PURE[@]}" "$TMP/verify_shared.luau" 2>&1 || true)"
if [ -n "$ANALYZE_OUT" ]; then
	echo "$ANALYZE_OUT"
	echo "analyze: FAILED (errors or lint warnings above)"
	exit 1
fi
echo "analyze: clean"

echo "== syntax check on ${#ROBLOX_ONLY[@]} Roblox-only modules + client scripts =="
for f in "${ROBLOX_ONLY[@]}" "$ROOT"/src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/*.luau; do
	"$COMPILE" "$f" > /dev/null
	echo "  ok  $(basename "$f")"
done

echo "== run verification =="
"$LUAU" "$TMP/verify_shared.luau"
