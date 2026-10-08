#!/usr/bin/env bash
# Offline check for the Shared modules (no Roblox Studio needed).
#
# Roblox modules use `require(script.Parent.X)`, which standalone Luau can't
# resolve. This script copies Shared/ to a temp dir, rewrites those requires to
# `require("./X")`, then runs `luau-analyze` (strict type check) and executes
# tools/verify_shared.luau and tools/verify_features.luau.
#
# Usage: LUAU_BIN=/path/to/dir/with/luau-and-luau-analyze tools/check.sh
#        (or put `luau` and `luau-analyze` on PATH)
#
# OPTIONAL real-Roblox-API check: also set LUAU_LSP=/path/to/luau-lsp and
# ROBLOX_TYPES=/path/to/globalTypes.d.luau (from the luau-lsp repo, scripts/).
# Then every Roblox-only script (services, remotes, all client code) is
# type-checked against the actual Roblox API (Instance, Players, RemoteEvent...).
# Diagnostics are only reported for those files: the pure modules are already
# covered by the stricter luau-analyze pass, and luau-lsp's newer solver is noisier
# about literal-type widening there.
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
cp "$ROOT/tools/verify_features.luau" "$TMP/verify_features.luau"

echo "== luau-analyze (strict) on ${#PURE[@]} pure modules =="
ANALYZE_OUT="$("$ANALYZE" "${PURE[@]}" "$TMP/verify_shared.luau" "$TMP/verify_features.luau" 2>&1 || true)"
if [ -n "$ANALYZE_OUT" ]; then
	echo "$ANALYZE_OUT"
	echo "analyze: FAILED (errors or lint warnings above)"
	exit 1
fi
echo "analyze: clean"

echo "== syntax check on ${#ROBLOX_ONLY[@]} Roblox-only modules + client scripts =="
for f in "${ROBLOX_ONLY[@]}" "$ROOT"/src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/*.luau "$ROOT"/src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/*/*.luau; do
	"$COMPILE" "$f" > /dev/null
	echo "  ok  $(basename "$f")"
done

if [ -n "${LUAU_LSP:-}" ] && [ -n "${ROBLOX_TYPES:-}" ]; then
	echo "== Roblox API type check (luau-lsp) on Roblox-only scripts =="
	python3 -I "$ROOT/tools/sourcemap.py" "$TMP/sourcemap.json" > /dev/null
	TARGET_FILES=()
	while IFS= read -r f; do
		if grep -q "ROBLOX-ONLY" "$f"; then TARGET_FILES+=("$f"); fi
	done < <(ls "$SHARED"/*.luau "$SERVER"/*.luau)
	for f in "$ROOT"/src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/*.luau "$ROOT"/src/StarterPlayer/StarterPlayerScripts/GolfRivals/Client/*/*.luau; do
		if [ -f "$f" ]; then TARGET_FILES+=("$f"); fi
	done
	TARGETS="$(printf '%s|' "${TARGET_FILES[@]}")"
	LSP_OUT="$("$LUAU_LSP" analyze --sourcemap "$TMP/sourcemap.json" --definitions="$ROBLOX_TYPES" "${TARGET_FILES[@]}" 2>&1 \
		| awk -v targets="$TARGETS" '
			BEGIN { n = split(targets, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") t[a[i]] = 1 }
			/^\[(INFO|WARN)\]/ { next }
			/^\// { keep = 0; for (k in t) if (index($0, k) == 1) keep = 1 }
			keep { print }' || true)"
	if [ -n "$LSP_OUT" ]; then
		echo "$LSP_OUT"
		echo "roblox types: FAILED"
		exit 1
	fi
	echo "roblox types: clean (${#TARGET_FILES[@]} scripts)"
fi

echo "== run verification =="
"$LUAU" "$TMP/verify_shared.luau"
"$LUAU" "$TMP/verify_features.luau"
