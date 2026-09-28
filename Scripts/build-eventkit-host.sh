#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
configuration=${CALOPOD_BUILD_CONFIGURATION:-debug}
case "$configuration" in
  debug|release) ;;
  *) echo "CALOPOD_BUILD_CONFIGURATION must be debug or release." >&2; exit 64 ;;
esac
bundle_root="$repository_root/.build/eventkit-host/Calopod EventKit Host.app"
contents_root="$bundle_root/Contents"
executable_root="$contents_root/MacOS"
executable_path="$executable_root/CalopodEventKitHost"

swift build \
  --package-path "$repository_root" \
  --configuration "$configuration" \
  --product calopod-eventkit-host
binary_root=$(swift build \
  --package-path "$repository_root" \
  --configuration "$configuration" \
  --show-bin-path)

mkdir -p "$executable_root"
cp "$repository_root/Support/EventKitHost/Info.plist" "$contents_root/Info.plist"
cp "$binary_root/calopod-eventkit-host" "$executable_path"
codesign --force --sign - "$bundle_root" >/dev/null 2>&1

echo "Built the EventKit host."
