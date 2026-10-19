#!/bin/sh
# Builds the iPhone app for a simulator, runs its tests and fails on any compiler warning from our own
# sources. It builds without signing, so it needs no team or profile. Set CALOPOD_IOS_SIMULATOR to a
# simulator id (from `xcrun simctl list devices`) to use instead of the first available iPhone.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
project="$repository_root/Apps/iOS/Calopod.xcodeproj"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/calopod-ios-check.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

simulator=${CALOPOD_IOS_SIMULATOR:-}
if [ -z "$simulator" ]; then
  # Names repeat across runtimes, so pick by id.
  simulator=$(xcrun simctl list devices available iPhone \
    | sed -n 's/^ *iPhone .* (\([0-9A-F-]\{36\}\)) .*/\1/p' | head -n 1)
fi
[ -n "$simulator" ] || { echo "No iPhone simulator is available." >&2; exit 1; }

echo "Building and testing on $simulator..."
if ! xcodebuild test -project "$project" -scheme Calopod \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$work_dir/derived" \
  CODE_SIGNING_ALLOWED=NO > "$work_dir/log" 2>&1; then
  grep -E 'error:|Test Case .* failed' "$work_dir/log" | cut -c1-300 >&2 || true
  echo "The iOS build or tests failed." >&2
  exit 1
fi

grep -E "^$repository_root/Apps/iOS/[^ ]*: warning: " "$work_dir/log" | sort -u > "$work_dir/warnings" || true
if [ -s "$work_dir/warnings" ]; then
  echo "Build warnings in the iPhone app:" >&2
  sed "s|^$repository_root/||" "$work_dir/warnings" >&2
  exit 1
fi
echo "The iPhone app builds and its tests pass, with no warnings."
