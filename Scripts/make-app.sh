#!/bin/bash
# Wraps the SwiftPM executable into a real .app bundle.
#
# Needed because this Mac has the command line tools only, so there is no Xcode app target to
# produce one. Without a bundle the program has no identifier, no icon and no Dock presence, and
# macOS treats it as a loose binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Porterage.app"
BUNDLE_ID="app.porterage"
VERSION="0.1.0"
MIN_MACOS="14.0"

cd "$ROOT"

if [ ! -f Vendor/lib/libusb-1.0.a ]; then
  echo "Vendor/lib/libusb-1.0.a is missing — run Scripts/build-libusb.sh first." >&2
  exit 1
fi

# Release builds are universal so one download runs on both Apple silicon and Intel. Debug builds
# stay host-only: they are rebuilt constantly and the second slice doubles the wait for nothing.
#
# `swift build --arch arm64 --arch x86_64` would be the obvious way, but it needs xcbuild from a full
# Xcode install. Building each slice into its own scratch directory and lipo-ing them works with the
# command line tools alone.
if [ "$CONFIG" = "release" ]; then
  swift build -c release 2>&1 | grep -v "^\[" || true
  swift build -c release --scratch-path .build-x86 \
    -Xswiftc -target -Xswiftc "x86_64-apple-macosx$MIN_MACOS" \
    -Xcc -arch -Xcc x86_64 -Xlinker -arch -Xlinker x86_64 2>&1 | grep -v "^\[" || true
  BINARY="$ROOT/build/PorterageApp-universal"
  lipo -create .build/release/PorterageApp .build-x86/release/PorterageApp -output "$BINARY"
else
  swift build -c "$CONFIG" 2>&1 | grep -v "^\[" || true
  BINARY=".build/$CONFIG/PorterageApp"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/PorterageApp"
cp "$ROOT/Resources/Porterage.icns" "$APP/Contents/Resources/Porterage.icns"
rm -f "$ROOT/build/PorterageApp-universal"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Porterage</string>
  <key>CFBundleDisplayName</key>       <string>Porterage</string>
  <key>CFBundleExecutable</key>        <string>PorterageApp</string>
  <key>CFBundleIconFile</key>          <string>Porterage</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSHumanReadableCopyright</key>  <string>Open source</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally. Public distribution additionally needs a Developer
# ID certificate and notarisation.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "warning: could not sign; the app still runs on this machine"

echo "built: $APP"
