#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${SHIFTDROP_VERSION:-0.1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "SHIFTDROP_VERSION must be a three-part numeric version." >&2
  exit 1
fi
if [[ ! -f assets/AppIcon.icns ]]; then
  swift scripts/make-icon.swift
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/shiftdrop-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# Stage outside cloud-synced folders so Finder metadata cannot break signing.
swift build -c release --scratch-path "$STAGING/build"
BIN_PATH="$(swift build -c release --scratch-path "$STAGING/build" --show-bin-path)"
APP="$STAGING/ShiftDrop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/ShiftDrop" "$APP/Contents/MacOS/ShiftDrop"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ShiftDrop</string>
  <key>CFBundleDisplayName</key><string>ShiftDrop</string>
  <key>CFBundleIdentifier</key><string>dev.nazeeh.shiftdrop</string>
  <key>CFBundleExecutable</key><string>ShiftDrop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Nazeeh Abdul-Hadi</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Convertible media</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.image</string><string>public.audio</string><string>public.movie</string><string>com.adobe.pdf</string><string>public.text</string><string>public.folder</string><string>public.data</string></array>
  </dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
ZIP="$STAGING/ShiftDrop-$VERSION-macOS.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$ROOT/dist"
/usr/bin/ditto "$APP" "$ROOT/dist/ShiftDrop.app"
cp "$ZIP" "$ROOT/dist/"
echo "Packaged: $ROOT/dist/ShiftDrop.app"
echo "Archive: $ROOT/dist/$(basename "$ZIP")"
