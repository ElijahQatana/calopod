#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bundle_path="$repository_root/.build/eventkit-probe/CalopodEventKitProbe.app"
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-eventkit-interactive.XXXXXX")
stdout_path="$probe_root/stdout.log"
stderr_path="$probe_root/stderr.log"

cleanup() {
  rm -rf "$probe_root"
}
trap cleanup EXIT

if [ ! -d "$bundle_path" ]; then
  echo "Build the EventKit probe first." >&2
  exit 66
fi

open -W -n \
  --stdout "$stdout_path" \
  --stderr "$stderr_path" \
  "$bundle_path" \
  --args --request

if [ -s "$stdout_path" ]; then
  cat "$stdout_path"
fi

if [ -s "$stderr_path" ]; then
  cat "$stderr_path" >&2
  exit 1
fi
