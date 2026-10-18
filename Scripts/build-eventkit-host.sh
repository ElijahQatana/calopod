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
mkdir -p "$contents_root/Resources"
cp "$repository_root/Support/EventKitHost/Info.plist" "$contents_root/Info.plist"
plutil -lint "$contents_root/Info.plist" >/dev/null
"$repository_root/Scripts/build-calopod-icon.sh" "$contents_root/Resources"
cp "$binary_root/calopod-eventkit-host" "$executable_path"
# CALOPOD_SIGN_IDENTITY signs with a developer identity; the default is ad hoc.
codesign --force --sign "${CALOPOD_SIGN_IDENTITY:--}" "$bundle_root" >/dev/null 2>&1

echo "Built the EventKit host."
