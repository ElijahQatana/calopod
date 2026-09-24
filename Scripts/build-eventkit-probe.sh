#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
source_root="$repository_root/Spikes/EventKitAccess"
bundle_root="$repository_root/.build/eventkit-probe/CalopodEventKitProbe.app"
module_cache="$repository_root/.build/module-cache"
contents_root="$bundle_root/Contents"
executable_root="$contents_root/MacOS"
executable_path="$executable_root/CalopodEventKitProbe"

mkdir -p "$executable_root"
cp "$source_root/Info.plist" "$contents_root/Info.plist"

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  -target "$(uname -m)-apple-macosx14.0" \
  "$source_root/EventKitAccessProbe.swift" \
  -o "$executable_path"

codesign --force --sign - "$bundle_root"

echo "Built $bundle_root"
