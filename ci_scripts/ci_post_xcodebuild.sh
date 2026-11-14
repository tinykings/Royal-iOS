#!/bin/sh
# Xcode Cloud: fill TestFlight "What to Test" with recent commit subjects.
set -e

# Only for builds that are going to TestFlight
if [ -n "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
  cd "$CI_PRIMARY_REPOSITORY_PATH"
  mkdir -p TestFlight
  git fetch --deepen=20 >/dev/null 2>&1 || true   # Xcode Cloud clones may be shallow
  git log -10 --no-merges --pretty=format:"- %s" | head -c 4000 > TestFlight/WhatToTest.en-US.txt
  cat TestFlight/WhatToTest.en-US.txt
fi
