#!/usr/bin/env bash
# Regenerates assets/animations/*.rbxmx (the golf KeyframeSequences) from
# Shared/SwingPose. Usage: LUAU_BIN=/path/to/luau/bin tools/gen_animations.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/src/ReplicatedStorage/GolfRivals/Shared"
LUAU="${LUAU_BIN:+$LUAU_BIN/}luau"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for f in "$SHARED"/*.luau; do
	sed -E -e '/OFFLINE-STRIP/d' -e 's/require\(script\.Parent\.([A-Za-z0-9_]+)\)/require(".\/\1")/g' "$f" > "$TMP/$(basename "$f")"
done
cp "$ROOT/tools/gen_animations.luau" "$TMP/gen_animations.luau"
OUT="$ROOT/assets/animations"
mkdir -p "$OUT"
rm -f "$OUT"/*.rbxmx
(cd "$TMP" && "$LUAU" gen_animations.luau) | awk -v out="$OUT" '
	/^=====FILE .*=====$/ { name = $2; sub(/=====$/, "", name); file = out "/" name; next }
	/^=====END=====$/ { file = ""; next }
	file != "" { print > file }
'
ls -1 "$OUT"
