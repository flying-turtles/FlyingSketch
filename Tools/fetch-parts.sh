#!/usr/bin/env bash
# Fetch pinned Fritzing part repos into Vendor/ (gitignored).
set -euo pipefail

FRITZING_PARTS_SHA="27535f2fd02097be9bed229b75aa8e9be282a4a0"
ADAFRUIT_LIBRARY_SHA="44c92aff21829c5ef2bd9babae1dc1e130a8f9af"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/Vendor"

fetch() {  # name url sha
  local dir="$ROOT/Vendor/$1"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$3" ]; then
    echo "$1 already at $3"
    return
  fi
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$2"
  git -C "$dir" fetch -q --depth 1 origin "$3"
  git -C "$dir" checkout -q FETCH_HEAD
  echo "$1 at $(git -C "$dir" rev-parse HEAD)"
}

fetch fritzing-parts https://github.com/fritzing/fritzing-parts "$FRITZING_PARTS_SHA"
fetch Fritzing-Library https://github.com/adafruit/Fritzing-Library "$ADAFRUIT_LIBRARY_SHA"
