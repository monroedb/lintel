#!/bin/bash
# Builds a release Lintel.app (scripts/build-app.sh, same signing rules) and installs it as
# /Applications/Lintel.app, replacing an earlier Lintel there.
#   DEST=/path/to/Lintel.app to install somewhere else.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-/Applications/Lintel.app}"
BUNDLE_ID="com.sashagilliard.lintel"

if pgrep -f "^$DEST/Contents/MacOS/Lintel( |$)" >/dev/null; then
  echo "error: Lintel is running from $DEST. Quit it (Quit Lintel in the menu-bar item's menu or the island's right-click menu) and run this again." >&2
  exit 1
fi
if [ -e "$DEST" ]; then
  existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing" != "$BUNDLE_ID" ]; then
    echo "error: $DEST exists but isn't Lintel (bundle ID \"$existing\"); not replacing it." >&2
    exit 1
  fi
fi

# Designated requirement of a bundle: what macOS matches every privacy permission against.
requirement() { codesign -d -r- "$1" 2>/dev/null | sed -nE 's/^(# )?designated => //p' || true; }
# The same without personal details: ad-hoc cdhash prefix or the certificate's kind.
describe() {
  case "$1" in
    "cdhash H\""*) echo "an ad-hoc build (cdhash ${1:9:8}…)" ;;
    *'leaf[subject.CN] = "'*)
      local cn="${1#*leaf\[subject.CN\] = \"}"
      echo "the \"${cn%%:*}\" certificate" ;;
    "") echo "unsigned" ;;
    *) echo "another signature" ;;
  esac
}
OLD_REQUIREMENT=""
[ -e "$DEST" ] && OLD_REQUIREMENT="$(requirement "$DEST")"

CONFIG=release "$ROOT/scripts/build-app.sh" >/dev/null
APP="$ROOT/build/Lintel.app"

# Copy next to the destination first, so a failed copy never leaves a half-installed app.
STAGE="$(dirname "$DEST")/.Lintel-install-$$.app"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE"
codesign --verify --strict "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"

codesign --verify --strict --verbose=1 "$DEST"
codesign -dv "$DEST" 2>&1 | grep -E '^(Authority|TeamIdentifier|Signature)=' | head -3 >&2 || true

# LaunchServices: forget copies that no longer exist and the development build, so System Settings
# (and `open -b`) resolve Lintel to the installed copy. With several registered copies of one bundle
# ID, a permission can end up recorded for the wrong copy.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" '
    /^path:/ { p = $0; sub(/^path:[ \t]+/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p) }
    $1 == "identifier:" && $2 == id { print p }' | sort -u | while IFS= read -r path; do
    if [ "$path" != "$DEST" ] && { [ ! -e "$path" ] || [ "$path" = "$APP" ]; }; then
      "$LSREGISTER" -u "$path" >/dev/null 2>&1 && echo "LaunchServices: forgot $path" >&2 || true
    fi
  done
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi

echo "Installed $DEST" >&2
NEW_REQUIREMENT="$(requirement "$DEST")"
if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]; then
  # macOS keeps each permission for the requirement it was granted to (README › Signing). An entry
  # granted to the replaced copy still shows on in System Settings but doesn't apply to this one, and
  # toggling it keeps the old requirement.
  cat >&2 <<NOTE
note: the code signature changed: the copy you replaced was $(describe "$OLD_REQUIREMENT"), this one is
      $(describe "$NEW_REQUIREMENT"). Permissions you gave the earlier copy don't apply to this one, even
      where System Settings shows them on, and switching them off and on doesn't change that.
      In System Settings › Privacy & Security, under Accessibility (volume and brightness keys) and
      Full Disk Access (Focus): select Lintel, click −, then click + and choose $DEST.
      Calendars, Location, Bluetooth and system audio recording: allow them again when Lintel asks.
NOTE
elif codesign -dv "$DEST" 2>&1 | grep -q '^Signature=adhoc'; then
  echo "note: this copy is signed ad-hoc, so macOS treats it as a new app: allow Accessibility, Full Disk Access and the other permissions again (README › Signing)." >&2
fi
