#!/bin/bash
# Build and notarize locally; publishing is a separate, explicit step.
set -euo pipefail
if [[ $# -ne 2 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $2 =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: bash scripts/release.sh VERSION BUILD_NUMBER" >&2
  exit 1
fi
: "${SKITCHISH_SIGN_IDENTITY:?Set the full Developer ID Application signing identity}"
: "${SKITCHISH_NOTARY_PROFILE:?Set a notarytool Keychain profile name}"
case "$SKITCHISH_SIGN_IDENTITY" in
  "Developer ID Application: "*) ;;
  *) echo "A Developer ID Application identity is required" >&2; exit 1 ;;
esac
project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$1"
release_dir="$project_root/build/releases/$version"
if [[ -e "$release_dir" ]]; then
  echo "Release directory already exists: $release_dir. Choose a new version or move it aside." >&2
  exit 1
fi
mkdir -p "$release_dir"
xcodebuild -project "$project_root/Skitchish.xcodeproj" -scheme Skitchish \
  -configuration Release -derivedDataPath "$release_dir/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$2" build
app="$release_dir/Skitchish.app"
ditto "$release_dir/DerivedData/Build/Products/Release/Skitchish.app" "$app"
lipo "$app/Contents/MacOS/Skitchish" -verify_arch arm64
lipo "$app/Contents/MacOS/Skitchish" -verify_arch x86_64
codesign --force --options runtime --timestamp \
  --entitlements "$project_root/Skitchish/Skitchish.entitlements" \
  --sign "$SKITCHISH_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
submission="$release_dir/notarization.zip"
ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$SKITCHISH_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
archive="$release_dir/Skitchish-$version.zip"
ditto -c -k --keepParent "$app" "$archive"
(cd "$release_dir" && shasum -a 256 "Skitchish-$version.zip") > "$release_dir/SHA256SUMS"
bash "$project_root/scripts/generate-cask.sh" "$version" "$archive" > "$release_dir/skitchish.rb"
printf 'Release prepared (not published): %s\n' "$release_dir"
