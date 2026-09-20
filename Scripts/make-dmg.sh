#!/bin/bash
# Packages build/Porterage.app into a disk image for GitHub Releases.
#
# A .dmg rather than a .zip because it is what Mac users expect to mount, and because it gives the
# window an Applications shortcut to drag onto. Signing and notarisation are a separate step and are
# not done here — see the notes at the bottom of this file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Porterage.app"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)"
STAGE="$ROOT/build/dmg"
DMG="$ROOT/build/Porterage-$VERSION.dmg"

if [ ! -d "$APP" ]; then
  echo "build/Porterage.app is missing — run Scripts/make-app.sh release first." >&2
  exit 1
fi

# Refuse to ship a host-only build: an Intel Mac downloading an arm64-only .dmg gets a crash, not a
# message, and the difference is invisible on the machine that built it.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/PorterageApp")"
case "$ARCHS" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) echo "refusing: the app is $ARCHS only. Build with Scripts/make-app.sh release." >&2; exit 1 ;;
esac

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The instruction has to travel inside the image. Until the app is signed, macOS refuses the first
# launch, and the moment that happens the person is looking at this window — not at the website and
# not at the release notes, where the same paragraph already sits and is already too late.
cat > "$STAGE/How to open it the first time.txt" <<'README'
Porterage — opening it the first time
=====================================

1. Drag Porterage onto the Applications folder beside it.

2. Open it. macOS will refuse, with a message saying it cannot be opened.
   This is expected. Porterage is not signed by Apple yet.

3. Open System Settings, go to Privacy & Security, and scroll down to the
   Security section. There will be a line about Porterage being blocked,
   with an "Open Anyway" button. Click it, and confirm.

   That button only appears for about an hour after step 2, so do step 2
   first. On macOS 15 and later, Control-clicking the app no longer works
   as a shortcut around this.

4. Open Porterage again. It starts normally, and you never see this again.

Why the detour: signing requires a paid Apple Developer account, which this
project does not have yet. Nothing about step 3 is specific to this app —
macOS does it to every application that is not signed.

Then plug the phone in with a USB cable, and on the phone choose
"File transfer" when it asks what the cable is for. Many charging cables
carry power only; if nothing appears, try a different cable first.

Free and open source, Apache-2.0.
Source and every measurement:  https://github.com/aiusmarcusx/porterage
The app makes no network connections and sends no telemetry.
README

hdiutil create \
  -volname "Porterage $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"

echo "built: $DMG"
echo "  $(du -h "$DMG" | cut -f1) · $ARCHS · minimum macOS $(defaults read "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
echo
echo "Not signed with a Developer ID. macOS REFUSES the first launch (spctl: rejected), and since"
echo "macOS 15 Control-click no longer overrides it — the user has to allow the app once in"
echo "System Settings > Privacy & Security. To fix that properly, once an Apple"
echo "Developer account exists and its certificate is installed:"
echo
echo "  codesign --force --deep --options runtime --timestamp \\"
echo "    --sign \"Developer ID Application: YOUR NAME (TEAMID)\" \"$APP\""
echo "  xcrun notarytool submit \"$DMG\" --keychain-profile porterage --wait"
echo "  xcrun stapler staple \"$DMG\""
