#!/bin/bash
# Builds ungive/mediaremote-adapter (BSD 3-Clause; git submodule at ThirdParty/mediaremote-adapter,
# pinned to a reviewed commit) with CMake into build/adapter. Skips the build when the outputs are
# newer than the submodule's commit. Prints the output directory.
#   Needs: cmake (e.g. `brew install cmake`) and the Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ThirdParty/mediaremote-adapter"
OUT="$ROOT/build/adapter"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  git -C "$ROOT" submodule update --init ThirdParty/mediaremote-adapter >&2
fi
command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }

COMMIT="$(git -C "$SRC" rev-parse HEAD)"
STAMP="$OUT/.built-commit"
if [ -d "$OUT/MediaRemoteAdapter.framework" ] && [ -x "$OUT/MediaRemoteAdapterTestClient" ] \
   && [ "$(cat "$STAMP" 2>/dev/null)" = "$COMMIT" ]; then
  echo "$OUT"
  exit 0
fi

rm -rf "$OUT"
cmake -S "$SRC" -B "$OUT" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 >&2
cmake --build "$OUT" --config Release >&2
echo "$COMMIT" > "$STAMP"
echo "$OUT"
