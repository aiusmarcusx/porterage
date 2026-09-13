#!/bin/bash
# Builds libusb from source into Vendor/, for the macOS version this app actually claims to support.
#
# Homebrew's libusb is compiled for whatever macOS the build machine runs. Linking that archive into
# an app with an older LSMinimumSystemVersion produces "built for newer macOS version" warnings and
# a binary that can fail on the older systems it advertises. This builds it correctly, and universal,
# so one download works on both Apple silicon and Intel.
#
# Run once; Package.swift picks up Vendor/lib/libusb-1.0.a automatically when it exists.
set -euo pipefail

VERSION="${LIBUSB_VERSION:-1.0.30}"
DEPLOYMENT_TARGET="${MACOS_MIN:-14.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="$VENDOR/src"
TARBALL="libusb-$VERSION.tar.bz2"
URL="https://github.com/libusb/libusb/releases/download/v$VERSION/$TARBALL"

rm -rf "$WORK" "$VENDOR/lib" "$VENDOR/include"
mkdir -p "$WORK" "$VENDOR/lib" "$VENDOR/include"
cd "$WORK"

echo "Fetching $URL"
curl -fsSL -o "$TARBALL" "$URL"
echo "sha256: $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
tar xjf "$TARBALL"
SRC="$WORK/libusb-$VERSION"

# One pass per architecture, then lipo the two archives together.
for arch in arm64 x86_64; do
  build="$WORK/build-$arch"
  mkdir -p "$build"
  cd "$build"
  host="$arch-apple-darwin"
  "$SRC/configure" \
    --host="$host" \
    --disable-shared --enable-static --disable-udev --disable-examples-build --disable-tests-build \
    CC="clang -arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    CFLAGS="-O2 -arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  cp libusb/.libs/libusb-1.0.a "$VENDOR/lib/libusb-1.0-$arch.a"
  echo "built $arch"
done

lipo -create "$VENDOR/lib/libusb-1.0-arm64.a" "$VENDOR/lib/libusb-1.0-x86_64.a" \
  -output "$VENDOR/lib/libusb-1.0.a"
rm -f "$VENDOR/lib/libusb-1.0-arm64.a" "$VENDOR/lib/libusb-1.0-x86_64.a"
mkdir -p "$VENDOR/include/libusb-1.0"
cp "$SRC/libusb/libusb.h" "$VENDOR/include/libusb-1.0/libusb.h"
rm -rf "$WORK"

echo
echo "Vendor/lib/libusb-1.0.a  —  $(lipo -archs "$VENDOR/lib/libusb-1.0.a"), minimum macOS $DEPLOYMENT_TARGET"
