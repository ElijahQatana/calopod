#!/bin/sh

set -eu
umask 077
repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
icon_test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-icon-test.XXXXXX")
trap 'rm -rf "$icon_test_root"' EXIT HUP INT TERM

"$repository_root/Scripts/build-calopod-icon.sh" "$icon_test_root/compiled" > /dev/null
[ -s "$icon_test_root/compiled/Assets.car" ]
[ "$(od -An -tx1 -N4 "$icon_test_root/compiled/Calopod.icns" | tr -d ' \n')" = 69636e73 ]
sips -s format png "$icon_test_root/compiled/Calopod.icns" \
  --out "$icon_test_root/fallback.png" > /dev/null 2>&1
[ -s "$icon_test_root/fallback.png" ]

icon_developer_root=$(xcode-select -p)
icon_renderer="$icon_developer_root/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$icon_renderer" ] || { echo "The Icon Composer renderer is unavailable." >&2; exit 69; }
for icon_appearance in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  "$icon_renderer" "$repository_root/Support/EventKitHost/Calopod.icon" \
    --export-image \
    --output-file "$icon_test_root/$icon_appearance.png" \
    --platform macOS --rendition "$icon_appearance" \
    --width 256 --height 256 --scale 1 > /dev/null 2>&1
  [ -s "$icon_test_root/$icon_appearance.png" ]
done
echo "Native icon compilation, fallback, and six appearance checks passed."
