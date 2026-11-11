#!/bin/sh
# Copies the modules shared with the Royal extension, byte for byte, from a
# Royal-iOS checkout (default: a sibling folder). Run after they change there,
# then `node --test`.
set -eu
cd "$(dirname "$0")/.."
src="${1:-../Royal-iOS/desktop}"
for file in cloudkit.mjs library.mjs store.mjs sync.mjs sync-runner.mjs preferences.mjs style.css; do
  cp "$src/$file" "shared/$file"
done
cp "$src/fake-cloudkit.mjs" tests/fake-cloudkit.mjs
echo "Copied shared files from $src"
