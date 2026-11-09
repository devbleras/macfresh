#!/bin/bash
# Builds MacFresh.app into ./build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="$ROOT/build/MacFresh.app"
VERSION="${VERSION:-1.0.0}"

echo "▸ Generando traducciones…"
python3 "$ROOT/scripts/l10n/build_strings.py"

echo "▸ Compilando ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacFresh"

echo "▸ Creando bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacFresh"

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  echo "▸ Generando icono…"
  rm -rf "$ROOT/build/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset"
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacFresh</string>
  <key>CFBundleDisplayName</key><string>MacFresh</string>
  <key>CFBundleIdentifier</key><string>com.macfresh.app</string>
  <key>CFBundleExecutable</key><string>MacFresh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 MacFresh</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>MacFresh usa System Events para gestionar los ítems de inicio y el Finder para vaciar la Papelera.</string>
</dict>
</plist>
PLIST

echo "▸ Firmando (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Listo: $APP"
