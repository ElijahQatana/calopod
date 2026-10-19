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
swift build --package-path "$repository_root" --configuration "$configuration" --product calopod
CALOPOD_BUILD_CONFIGURATION="$configuration" "$repository_root/Scripts/build-eventkit-host.sh"
binary_root=$(swift build \
  --package-path "$repository_root" \
  --configuration "$configuration" \
  --show-bin-path)

rm -rf "$bundle_root"
mkdir -p "$contents_root/MacOS" "$contents_root/Resources" "$contents_root/Library/LaunchAgents"
sed "s/__VERSION__/$version/" "$repository_root/Support/Mac/Info.plist" > "$contents_root/Info.plist"
cp "$repository_root/Support/Mac/$agent_plist_name" "$contents_root/Library/LaunchAgents/$agent_plist_name"
# Public OAuth client IDs only, never secrets.
for pair in CalopodGoogleClientID:CALOPOD_GOOGLE_CLIENT_ID \
  CalopodMicrosoftClientID:CALOPOD_MICROSOFT_CLIENT_ID \
  CalopodMicrosoftTenant:CALOPOD_MICROSOFT_TENANT; do
  value=$(printenv "${pair#*:}" || true)
  if [ -n "$value" ]; then
    plutil -insert "${pair%%:*}" -string "$value" "$contents_root/Info.plist"
  fi
done
plutil -lint "$contents_root/Info.plist" "$contents_root/Library/LaunchAgents/$agent_plist_name" >/dev/null
"$repository_root/Scripts/build-calopod-icon.sh" "$contents_root/Resources"
cp "$binary_root/calopod-mac" "$contents_root/MacOS/CalopodMac"
cp "$binary_root/calopod-agent" "$contents_root/MacOS/calopod-agent"
cp "$binary_root/calopod" "$contents_root/MacOS/calopod"
# The agent and the command look for `eventkit-host` next to its own executable.
mkdir -p "$contents_root/MacOS/eventkit-host"
cp -R "$repository_root/.build/eventkit-host/Calopod EventKit Host.app" \
  "$contents_root/MacOS/eventkit-host/"
# CALOPOD_SIGN_IDENTITY signs like a release: hardened runtime and a timestamp on every item, and
# the Calendar entitlement on the helper, the agent, the command and the app. macOS charges the
# helper's Calendar request to the outer app, so the app needs it too. The default is ad hoc. Sign inside out.
. "$repository_root/Scripts/calopod-codesign.sh"
sign_identity=${CALOPOD_SIGN_IDENTITY:--}
host_path="$contents_root/MacOS/eventkit-host/Calopod EventKit Host.app"
sign_failed() {
  echo "Could not sign $1." >&2
  exit 65
}
if [ "$sign_identity" = "-" ]; then
  calopod_sign_item codesign "$sign_identity" "$host_path" || sign_failed "the Calendar helper"
else
  calopod_sign_item codesign "$sign_identity" "$host_path" \
    --entitlements "$repository_root/Support/EventKitHost/Entitlements.plist" \
    || sign_failed "the Calendar helper"
fi
outer_entitlements="$repository_root/Support/Mac/Entitlements.plist"
sign_outer() {
  item=$1
  label=$2
  if [ "$sign_identity" = "-" ]; then
    calopod_sign_item codesign "$sign_identity" "$item" || sign_failed "$label"
  else
    calopod_sign_item codesign "$sign_identity" "$item" --entitlements "$outer_entitlements" \
      || sign_failed "$label"
  fi
}
sign_outer "$contents_root/MacOS/calopod-agent" "calopod-agent"
sign_outer "$contents_root/MacOS/calopod" "calopod"
sign_outer "$bundle_root" "the app"
codesign --verify --strict --deep "$bundle_root" || sign_failed "the app (verification failed)"
calopod_show_signature codesign "$host_path"
calopod_show_signature codesign "$contents_root/MacOS/calopod-agent"
calopod_show_signature codesign "$contents_root/MacOS/calopod"
calopod_show_signature codesign "$bundle_root"

echo "Built $bundle_root"
