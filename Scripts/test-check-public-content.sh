#!/bin/sh
# Stages small files in a scratch repository and checks which ones Scripts/check-public-content.sh blocks.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/calopod-public-test.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

cd "$work_dir"
git init -q .
git config user.name Test
git config user.email test@example.com

# check <pass|block> <path> <content>
check() {
  expected=$1 path=$2 content=$3
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  git add -f "$path"
  if "$repository_root/Scripts/check-public-content.sh" > /dev/null 2>&1; then actual=pass; else actual=block; fi
  git rm -q -f --cached "$path"
  rm -f "$path"
  [ "$actual" = "$expected" ] || { echo "Expected $expected for $path: $content" >&2; exit 1; }
}

check pass Apps/iOS/README.md 'See background@2x.png and user@example.com.'
# The address is built here so this file does not contain one for the check to flag.
check block Apps/iOS/README.md "Ask someone$(printf '\100')mail.test.org."
check pass Apps/iOS/Config.xcconfig '// Put DEVELOPMENT_TEAM in Local.xcconfig'
check pass Apps/iOS/Config.xcconfig 'DEVELOPMENT_TEAM ='
check block Apps/iOS/Config.xcconfig 'DEVELOPMENT_TEAM = YOUR_TEAM_ID'
check block Apps/iOS/Other.xcconfig '  DEVELOPMENT_TEAM=ABCDE12345'
check block Apps/iOS/Calopod.xcodeproj/project.pbxproj 'DEVELOPMENT_TEAM = ABCDE12345;'
check pass Apps/iOS/README.md 'Set DEVELOPMENT_TEAM = YOUR_TEAM_ID in Local.xcconfig.'
check block docs/releasing.md 'Team ID: ABCDE12345'
check block Apps/iOS/Calopod.entitlements 'ABCDE12345.pro.example.app'
check block Apps/iOS/notes.md 'Identity 0123456789abcdef0123456789ABCDEF01234567'
check pass .github/workflows/ci.yml 'uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v4'
check block Apps/iOS/Calopod.provisionprofile 'x'
check block Apps/iOS/Calopod.mobileprovision 'x'

echo "Public-content check tests passed."
