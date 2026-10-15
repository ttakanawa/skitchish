#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_args=()
if [[ "${1:-}" != "--ui" ]]; then
  test_args+=("-only-testing:SkitchishTests")
fi
xcodebuild -project "$project_root/Skitchish.xcodeproj" -scheme Skitchish \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$project_root/build/TestDerivedData" \
  CODE_SIGN_IDENTITY="${SKITCHISH_SIGN_IDENTITY:--}" CODE_SIGNING_ALLOWED=YES \
  -parallel-testing-enabled NO \
  "${test_args[@]}" test
