#!/bin/zsh
set -euo pipefail

COPI_REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$COPI_REPOSITORY_ROOT"

xcodebuild \
  -project copi.xcodeproj \
  -scheme copi \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build-fixture \
  PRODUCT_BUNDLE_IDENTIFIER=com.jos.copi.visualfixture \
  build

open -n build-fixture/Build/Products/Debug/Copi.app \
  --args --overlay-visual-fixture
