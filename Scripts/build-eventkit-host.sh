#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bundle_root="$repository_root/.build/eventkit-host/Calopod EventKit Host.app"
contents_root="$bundle_root/Contents"
executable_root="$contents_root/MacOS"
executable_path="$executable_root/CalopodEventKitHost"

swift build --package-path "$repository_root" --product calopod-eventkit-host
binary_root=$(swift build --package-path "$repository_root" --show-bin-path)

mkdir -p "$executable_root"
cp "$repository_root/Support/EventKitHost/Info.plist" "$contents_root/Info.plist"
cp "$binary_root/calopod-eventkit-host" "$executable_path"
codesign --force --sign - "$bundle_root"

echo "Built $bundle_root"
