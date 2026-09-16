#!/bin/bash
# Renders Resources/icon.html into Resources/Porterage.icns.
#
# This Mac has no image tooling beyond what ships with macOS, so the icon is drawn in CSS and
# photographed by headless Chrome, then reduced with sips — the same route the website's own social
# image takes. Run it only when the icon changes; the .icns is committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
ICONSET="$WORK/Porterage.iconset"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$CHROME" ]; then
  echo "Google Chrome is needed to render the icon." >&2
  exit 1
fi

mkdir -p "$ICONSET"
# Chrome writes the screenshot and then sits there, so it runs in the background and is stopped as
# soon as the file appears.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --default-background-color=00000000 \
  --screenshot="$WORK/icon-1024.png" --window-size=1024,1024 \
  --user-data-dir="$WORK/chrome" \
  "file://$ROOT/Resources/icon.html" >/dev/null 2>&1 &
CHROME_PID=$!
for _ in $(seq 1 60); do
  [ -s "$WORK/icon-1024.png" ] && break
  sleep 0.5
done
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
if [ ! -s "$WORK/icon-1024.png" ]; then
  echo "Chrome did not produce a screenshot." >&2
  exit 1
fi

# Both sizes of each entry: macOS picks the one that matches the screen.
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -s format png -z "$((size * 2))" "$((size * 2))" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/Porterage.icns"
echo "built: Resources/Porterage.icns ($(du -h "$ROOT/Resources/Porterage.icns" | cut -f1))"
