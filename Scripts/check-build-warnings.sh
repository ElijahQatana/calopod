#!/bin/sh
# Builds everything, tests included, in a throwaway build folder and fails on any compiler warning
# from our own Sources or Tests. Run it by hand and before a release; it takes a few minutes.
# Warnings we cannot fix can be listed in Scripts/build-warnings-ignore.txt.

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
ignore_file="$repository_root/Scripts/build-warnings-ignore.txt"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/calopod-warning-check.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

: > "$work_dir/ignore"
if [ -f "$ignore_file" ]; then
  grep -v '^[[:space:]]*\(#\|$\)' "$ignore_file" > "$work_dir/ignore" || true
fi

: > "$work_dir/warnings"
for mode in debug release; do
  echo "Building ($mode) in a clean folder..."
  # The debug pass builds the tests too.
  if [ "$mode" = release ]; then set -- -c release; else set -- --build-tests; fi
  NO_COLOR=1 swift build --package-path "$repository_root" --build-path "$work_dir/build-$mode" "$@" \
    > "$work_dir/log-$mode" 2>&1 || { grep 'error:' "$work_dir/log-$mode" | cut -c1-300 >&2 || true; echo "The $mode build failed." >&2; exit 1; }
  grep -E "^$repository_root/(Sources|Tests)/[^ ]*: warning: " "$work_dir/log-$mode" \
    | sed -E "s|^$repository_root/||; s| \[#[A-Za-z]+\]\$||" >> "$work_dir/warnings" || true
done

sort -u "$work_dir/warnings" > "$work_dir/unique"
if [ -s "$work_dir/ignore" ]; then
  grep -v -F -f "$work_dir/ignore" "$work_dir/unique" > "$work_dir/remaining" || true
else
  cp "$work_dir/unique" "$work_dir/remaining"
fi

if [ -s "$work_dir/remaining" ]; then
  echo "Build warnings in our own code:" >&2
  cat "$work_dir/remaining" >&2
  exit 1
fi
echo "No build warnings in Sources or Tests."
