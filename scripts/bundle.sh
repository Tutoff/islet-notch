#!/bin/zsh
# Builds Islet in release mode and wraps it into dist/Islet.app, with the `islet` command-line tool in
# Contents/Helpers (not Contents/MacOS: "islet" and "Islet" collide on case-insensitive volumes), next to
# libIsletMediaRemote.dylib (Now Playing for apps other than Music and Spotify, loaded by /usr/bin/perl).
# Signs with the "Islet Dev" identity when the keychain has one (permission grants then survive rebuilds),
# ad-hoc otherwise.
# Usage: scripts/bundle.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Builds every product: the app (Islet) and the CLI (IsletCLI).
ARCH="${ISLET_ARCH:-$(uname -m)}"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

APP="$ROOT/dist/Islet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/Islet" "$APP/Contents/MacOS/Islet"
cp "$BIN_DIR/IsletCLI" "$APP/Contents/Helpers/islet"
strip -x "$APP/Contents/MacOS/Islet" "$APP/Contents/Helpers/islet"
# MediaRemote reader (Now Playing for every app), loaded by /usr/bin/perl: see Sources/NowPlayingFeature/Resources/IsletMediaRemote.h
clang -x objective-c -dynamiclib -fobjc-arc -O2 -arch "$ARCH" -mmacosx-version-min=14.0 \
    -framework Foundation -o "$APP/Contents/Helpers/libIsletMediaRemote.dylib" \
    "$ROOT/Sources/NowPlayingFeature/Resources/IsletMediaRemote.h"
strip -x "$APP/Contents/Helpers/libIsletMediaRemote.dylib"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Islet Dev"'; then
    IDENTITY="Islet Dev"
fi
# Inside out: the helpers first, then the app, whose seal covers them.
codesign --force --sign "$IDENTITY" --timestamp=none --identifier dev.islet.cli "$APP/Contents/Helpers/islet"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier dev.islet.mediaremote \
    "$APP/Contents/Helpers/libIsletMediaRemote.dylib"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed with ${IDENTITY/#-/ad-hoc identity}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Islet 2>/dev/null || true
    rm -rf /Applications/Islet.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Islet.app"
fi
