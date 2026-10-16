#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
configuration=${CALOPOD_BUILD_CONFIGURATION:-debug}
case "$configuration" in
  debug|release) ;;
  *) echo "CALOPOD_BUILD_CONFIGURATION must be debug or release." >&2; exit 64 ;;
esac
bundle_root="$repository_root/.build/mac-app/Calopod.app"
contents_root="$bundle_root/Contents"
agent_plist_name="pro.elijahquintana.calopod.app-agent.plist"
version=$(tr -d '[:space:]' < "$repository_root/VERSION")

swift build --package-path "$repository_root" --configuration "$configuration" --product calopod-mac
swift build --package-path "$repository_root" --configuration "$configuration" --product calopod-agent
CALOPOD_BUILD_CONFIGURATION="$configuration" "$repository_root/Scripts/build-eventkit-host.sh"
binary_root=$(swift build \
  --package-path "$repository_root" \
  --configuration "$configuration" \
  --show-bin-path)

rm -rf "$bundle_root"
mkdir -p "$contents_root/MacOS" "$contents_root/Resources" "$contents_root/Library/LaunchAgents"
sed "s/__VERSION__/$version/" "$repository_root/Support/Mac/Info.plist" > "$contents_root/Info.plist"
cp "$repository_root/Support/Mac/$agent_plist_name" "$contents_root/Library/LaunchAgents/$agent_plist_name"
plutil -lint "$contents_root/Info.plist" "$contents_root/Library/LaunchAgents/$agent_plist_name" >/dev/null
"$repository_root/Scripts/build-calopod-icon.sh" "$contents_root/Resources"
cp "$binary_root/calopod-mac" "$contents_root/MacOS/CalopodMac"
cp "$binary_root/calopod-agent" "$contents_root/MacOS/calopod-agent"
# The agent finds the host by searching up from its own executable for `eventkit-host`.
mkdir -p "$contents_root/MacOS/eventkit-host"
cp -R "$repository_root/.build/eventkit-host/Calopod EventKit Host.app" \
  "$contents_root/MacOS/eventkit-host/"
codesign --force --sign - "$bundle_root" >/dev/null 2>&1

echo "Built $bundle_root"
