#!/bin/bash
# Renders README screenshots (English + Spanish) into docs/screenshots/<lang>/*.jpg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacFresh.app/Contents/MacOS/MacFresh"
[ -x "$APP" ] || "$ROOT/scripts/build-app.sh"
for lang in en es; do
  out="$ROOT/docs/screenshots/$lang"
  rm -rf "$out"; mkdir -p "$out"
  "$APP" --screenshots "$out" -AppleLanguages "($lang)" >/dev/null 2>&1
  for png in "$out"/*.png; do
    sips -s format jpeg -s formatOptions 82 -Z 1600 "$png" --out "${png%.png}.jpg" >/dev/null
    rm "$png"
  done
done
echo "✓ Capturas en docs/screenshots"
