#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$project_root/Skitchish.xcodeproj" -scheme Skitchish \
  -configuration Release -derivedDataPath "$project_root/build/DerivedData" \
  CODE_SIGN_IDENTITY="${SKITCHISH_SIGN_IDENTITY:--}" build
ditto "$project_root/build/DerivedData/Build/Products/Release/Skitchish.app" "$project_root/build/Skitchish.app"
codesign --verify --deep --strict "$project_root/build/Skitchish.app"
printf 'Built: %s\n' "$project_root/build/Skitchish.app"
