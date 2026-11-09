#!/bin/bash
# Builds a universal MacFresh.app and packs it as build/MacFresh-<version>.zip for a GitHub Release.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export VERSION="${1:-1.0.0}"
UNIVERSAL=1 "$ROOT/scripts/build-app.sh" release
ZIP="$ROOT/build/MacFresh-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/MacFresh.app" "$ZIP"
echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1))"
shasum -a 256 "$ZIP"
