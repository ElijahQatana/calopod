#!/bin/sh

set -eu
umask 077

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
icon_output=${1:-"$repository_root/.build/calopod-icon"}
[ "$#" -le 1 ] || { echo "Usage: Scripts/build-calopod-icon.sh [OUTPUT_DIRECTORY]" >&2; exit 64; }
case "$icon_output" in
  /*) ;;
  *) echo "The icon output directory must be absolute." >&2; exit 78 ;;
esac
xcrun --find actool > /dev/null 2>&1 \
  || { echo "Install full Xcode with Icon Composer support to build the app icon." >&2; exit 69; }
mkdir -p "$icon_output"
icon_staging=$(mktemp -d "$icon_output/.calopod-icon.XXXXXX")
trap 'rm -rf "$icon_staging"' EXIT HUP INT TERM

if ! xcrun actool "$repository_root/Support/EventKitHost/Calopod.icon" \
  --compile "$icon_staging" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --target-device mac \
  --app-icon Calopod \
  --output-partial-info-plist "$icon_staging/Info.plist" \
  > "$icon_staging/compiler.log" 2>&1; then
  echo "The Calopod Icon Composer source could not be compiled. Check the Xcode version." >&2
  exit 65
fi

[ -s "$icon_staging/Assets.car" ] && [ -s "$icon_staging/Calopod.icns" ] \
  && [ "$(plutil -extract CFBundleIconName raw -o - "$icon_staging/Info.plist")" = Calopod ] \
  && [ "$(plutil -extract CFBundleIconFile raw -o - "$icon_staging/Info.plist")" = Calopod ] \
  || { echo "The compiled Calopod icon resources are incomplete." >&2; exit 65; }
install -m 600 "$icon_staging/Assets.car" "$icon_output/Assets.car"
install -m 600 "$icon_staging/Calopod.icns" "$icon_output/Calopod.icns"
echo "Compiled the Calopod icon and older-macOS fallback."
