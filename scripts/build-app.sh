#!/bin/bash
# Builds Lintel.app from the Swift package.
#   CONFIG=release|debug (default release)
#   ARCHS="arm64 x86_64" for a universal app (Apple Silicon and Intel); default: this Mac's only
#   SIGN_IDENTITY=<name or SHA-1>, or "-" for ad-hoc (default: the first Apple Development
#   identity in the keychain, else ad-hoc; see scripts/signing-identity.sh)
# Output: build/Lintel.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
# An installed Xcode whose license hasn't been accepted (`sudo xcodebuild -license`) blocks every
# toolchain command; the Command Line Tools still work, so build with them instead.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find swift >/dev/null 2>&1 \
   && [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  echo "note: Xcode's license isn't accepted yet (sudo xcodebuild -license); building with the Command Line Tools" >&2
fi
SIGNING="$("$ROOT/scripts/signing-identity.sh")"
IDENTITY="${SIGNING%%$'\t'*}"
IDENTITY_NAME="${SIGNING#*$'\t'}"
echo "Signing identity: $IDENTITY_NAME" >&2
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="$ROOT/build"
APP="$OUT/Lintel.app"

ARCH_FLAGS=()
for ARCH in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$ARCH"); done
swift build -c "$CONFIG" --package-path "$ROOT" --product Lintel ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/Lintel"

mkdir -p "$OUT"
if [ ! -f "$OUT/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$OUT/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$OUT/AppIcon.iconset" >/dev/null
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lintel"
if [ "$CONFIG" = release ]; then
  # The debug map lists the folders the sources were compiled in (a home folder, say); a release
  # build doesn't need it. Function names stay for crash reports.
  strip -S "$APP/Contents/MacOS/Lintel"
fi
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Lintel")" >&2
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Secure timestamps only for Developer ID (notarization needs them); development and ad-hoc
# builds stay offline.
case "$IDENTITY_NAME" in
  "Developer ID Application:"*) TIMESTAMP="--timestamp" ;;
  *) TIMESTAMP="--timestamp=none" ;;
esac

# MediaRemote adapter: bundled, never linked; run as /usr/bin/perl <script> <framework> stream.
ADAPTER="$("$ROOT/scripts/build-adapter.sh")"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Helpers" "$APP/Contents/Resources/MediaRemoteAdapter"
cp -R "$ADAPTER/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER/MediaRemoteAdapterTestClient" "$APP/Contents/Helpers/"
cp "$ROOT/ThirdParty/mediaremote-adapter/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/MediaRemoteAdapter/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
for NESTED in "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" "$APP/Contents/Helpers/MediaRemoteAdapterTestClient"; do
  codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$NESTED"
done
codesign --force --options runtime $TIMESTAMP --entitlements "$ROOT/Resources/Lintel.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"
# macOS keys privacy permissions to this requirement; it only stays the same across rebuilds when
# a certificate signs (ad-hoc requirements name the build's cdhash).
codesign -d -r- "$APP" 2>&1 | sed -nE 's/^(# )?designated => /Designated requirement: /p' >&2
echo "$APP"
