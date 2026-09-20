#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/smoke
swiftc -parse-as-library -swift-version 6 \
  Sources/Hunk/Domain.swift \
  Sources/Hunk/MockServices.swift \
  Sources/Hunk/ReviewStore.swift \
  scripts/SmokeTests.swift -o .build/smoke/ReviewSmokeTests
.build/smoke/ReviewSmokeTests
