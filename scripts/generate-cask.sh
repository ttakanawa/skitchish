#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! -f $2 ]]; then
  echo "Usage: bash scripts/generate-cask.sh VERSION RELEASE_ZIP" >&2
  exit 1
fi
checksum="$(shasum -a 256 "$2" | awk '{print $1}')"
cat <<EOF
cask "skitchish" do
  version "$1"
  sha256 "$checksum"

  url "https://github.com/ttakanawa/skitchish/releases/download/v#{version}/Skitchish-#{version}.zip"
  name "Skitchish"
  desc "Capture and annotate images"
  homepage "https://github.com/ttakanawa/skitchish"

  depends_on macos: :sequoia

  app "Skitchish.app"

  caveats "Requires macOS 15.1 or later."
end
EOF
