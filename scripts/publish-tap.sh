#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: bash scripts/publish-tap.sh VERSION" >&2
  exit 1
fi
: "${GH_TOKEN:?Set a token with write access to ttakanawa/homebrew-skitchish}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
gh release download "v$1" --repo ttakanawa/skitchish \
  --pattern "Skitchish-$1.zip" --pattern SHA256SUMS --dir "$work_dir"
(cd "$work_dir" && shasum -a 256 -c SHA256SUMS)
gh auth setup-git
gh repo clone ttakanawa/homebrew-skitchish "$work_dir/tap"
mkdir -p "$work_dir/tap/Casks"
if [[ -f "$work_dir/tap/Casks/skitchish.rb" ]]; then
  current_version="$(sed -n 's/^  version "\([0-9.]*\)"$/\1/p' "$work_dir/tap/Casks/skitchish.rb")"
  if [[ ! $current_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Cannot determine current Cask version; refusing to overwrite it' >&2
    exit 1
  fi
  if ! awk -v incoming="$1" -v current="$current_version" 'BEGIN {
    split(incoming, a, "."); split(current, b, ".");
    for (i = 1; i <= 3; i++) {
      if (a[i] + 0 > b[i] + 0) exit 0;
      if (a[i] + 0 < b[i] + 0) exit 1;
    }
    exit 0;
  }'; then
    echo "Refusing to downgrade Cask from $current_version to $1" >&2
    exit 1
  fi
fi
bash "$project_root/scripts/generate-cask.sh" "$1" "$work_dir/Skitchish-$1.zip" > "$work_dir/tap/Casks/skitchish.rb"
ruby -c "$work_dir/tap/Casks/skitchish.rb"
git -C "$work_dir/tap" config user.name 'github-actions[bot]'
git -C "$work_dir/tap" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$work_dir/tap" add Casks/skitchish.rb
if git -C "$work_dir/tap" diff --cached --quiet; then
  echo 'Tap already up to date'
  exit 0
fi
git -C "$work_dir/tap" commit -m "skitchish $1"
git -C "$work_dir/tap" push origin HEAD
