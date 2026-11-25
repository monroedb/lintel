#!/bin/bash
# Prints the code-signing identity for Lintel builds as "<identity><TAB><description>", where
# <identity> is the SHA-1 hash to pass to `codesign --sign`, or "-" for ad-hoc. Order:
#   1. SIGN_IDENTITY: an identity name or SHA-1 hash, or "-" for ad-hoc (the identity may be a
#      self-signed certificate that the keychain doesn't trust: codesign signs with it all the same);
#   2. the first valid "Apple Development" identity in the keychain (a free Apple ID personal-team
#      certificate created in Xcode qualifies);
#   3. ad-hoc, with a warning on stderr.
# A certificate keeps the app's designated requirement (bundle ID + certificate name) the same
# across rebuilds, so the privacy permissions you grant (Accessibility, Calendars, Location, …)
# carry over. An ad-hoc signature changes with every build, so macOS treats each rebuild as a new app.
set -euo pipefail

# "<SHA-1> <name>" for every valid code-signing identity in the keychain search list.
identities() {
  { security find-identity -v -p codesigning 2>/dev/null || true; } \
    | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"$/\1 \2/p'
}

# The same for every code-signing identity, valid or not (a self-signed certificate isn't trusted,
# so `find-identity -v` leaves it out; it is listed with a status such as CSSMERR_TP_NOT_TRUSTED).
all_identities() {
  { security find-identity -p codesigning 2>/dev/null || true; } \
    | sed -nE 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+"(.*)"( \([^"]*\))?$/\1 \2/p' \
    | sort -u
}

if [ -n "${SIGN_IDENTITY+set}" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    printf -- '-\tad-hoc (SIGN_IDENTITY=-)\n'
    exit 0
  fi
  # Names start after the 40-character hash and one space.
  match="$(all_identities | awk -v want="$SIGN_IDENTITY" \
    '{ hash = $1; name = substr($0, 42) } toupper(hash) == toupper(want) || name == want { print; exit }')"
  if [ -z "$match" ]; then
    echo "error: SIGN_IDENTITY \"$SIGN_IDENTITY\" isn't a valid code-signing identity in the keychain." >&2
    exit 1
  fi
  printf '%s\t%s\n' "${match%% *}" "${match#* }"
  exit 0
fi

match="$(identities | awk '{ name = substr($0, 42) } name ~ /^Apple Development: / { print; exit }')"
if [ -n "$match" ]; then
  printf '%s\t%s\n' "${match%% *}" "${match#* }"
  exit 0
fi

echo "warning: no Apple Development identity in the keychain, so Lintel is signed ad-hoc." >&2
echo "warning: macOS treats every ad-hoc rebuild as a new app, so permissions must be granted again (README › Signing)." >&2
printf -- '-\tad-hoc (no Apple Development identity found)\n'
