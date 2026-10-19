#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-dmg-test.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
mount_point="$test_root/mount"
cleanup() {
  hdiutil detach -quiet "$mount_point" > /dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

script="$repository_root/Scripts/make-calopod-dmg.sh"
app="$test_root/Calopod.app"
helper="$app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app"
out="$test_root/out"
log="$test_root/output.log"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.example.calopod</string>
<key>CFBundleExecutable</key><string>CalopodMac</string>
<key>CFBundleShortVersionString</key><string>9.8.7</string>
<key>CFBundleIconFile</key><string>Calopod</string>
</dict></plist>
PLIST
sed -e 's/test.example.calopod/test.example.calopod.host/' -e 's/CalopodMac/Host/' \
  "$app/Contents/Info.plist" > "$helper/Contents/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/CalopodMac"
cp "$app/Contents/MacOS/CalopodMac" "$helper/Contents/MacOS/Host"
chmod 755 "$app/Contents/MacOS/CalopodMac" "$helper/Contents/MacOS/Host"
# A small solid icon so the volume icon path runs.
python3 -I - "$test_root/icon.png" <<'PY'
import struct, sys, zlib
n = 256
raw = b"".join(b"\x00" + b"\xb4\x53\x09" * n for _ in range(n))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
sips -s format icns "$test_root/icon.png" --out "$app/Contents/Resources/Calopod.icns" > /dev/null 2>&1

# An unsigned app is refused without the flag.
if "$script" "$app" --output-directory "$out" > "$log" 2>&1; then
  echo "An unsigned app was packaged." >&2; exit 1
fi
grep -q 'Refusing to package' "$log"
[ ! -e "$out" ] || [ -z "$(ls "$out")" ]

codesign --force --sign - "$helper" > /dev/null 2>&1
codesign --force --sign - "$app" > /dev/null 2>&1

# An ad hoc app is refused too.
if "$script" "$app" --output-directory "$out" > "$log" 2>&1; then
  echo "An ad hoc app was packaged." >&2; exit 1
fi
grep -q 'Developer ID' "$log"

# With the flag it builds, warns, and reads the version.
"$script" "$app" --output-directory "$out" --allow-adhoc > "$log" 2>&1
grep -q 'not release-signed' "$log"
dmg="$out/Calopod-9.8.7.dmg"
[ -s "$dmg" ]
hdiutil verify -quiet "$dmg" > /dev/null
(cd "$out" && shasum -a 256 -c Calopod-9.8.7.dmg.sha256 > /dev/null)
grep -q 'Not notarized' "$log"

# Both backgrounds are exactly the window content size, from the shared layout file.
swift "$repository_root/Scripts/dmg/make-background.swift" "$repository_root/Scripts/dmg/layout.json" "$test_root/art" > /dev/null
layout_size() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["width"]*int(sys.argv[2]), d["height"]*int(sys.argv[2]))' "$repository_root/Scripts/dmg/layout.json" "$1"; }
image_size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w, h}'; }
[ "$(image_size "$test_root/art/background.png")" = "$(layout_size 1)" ]
[ "$(image_size "$test_root/art/background@2x.png")" = "$(layout_size 2)" ]

mkdir "$mount_point"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount_point" "$dmg" > /dev/null 2>&1
[ -d "$mount_point/Calopod.app/Contents/MacOS" ]
[ -L "$mount_point/Applications" ]
[ "$(readlink "$mount_point/Applications")" = /Applications ]
[ -f "$mount_point/.DS_Store" ]
[ -d "$mount_point/.background" ] || [ -f "$mount_point/.background.tiff" ]
[ -f "$mount_point/.VolumeIcon.icns" ]
# Only the app and the Applications link are visible; ls skips the hidden items.
[ "$(ls "$mount_point")" = "Applications
Calopod.app" ]
hdiutil detach -quiet "$mount_point"

# Nothing private reaches the output.
users_dir=/Users
if grep -Eq "$HOME|$users_dir/|Developer ID Application:" "$log"; then
  echo "The output named a home path or an identity." >&2; exit 1
fi

# Signed path with stub tools: the checks pass, the image is signed, notarization runs only on request.
tools="$test_root/tools"
calls="$test_root/calls"
mkdir -p "$tools"
cat > "$tools/codesign" <<STUB
#!/bin/sh
printf 'codesign %s\n' "\$*" >> "$calls"
case "\$1" in
  -dvv)
    echo 'Authority=Developer ID Application: Example Company (EXAMPLE123)' >&2
    echo 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1 location=embedded' >&2 ;;
  -d)
    if [ "\${TEST_NO_ENTITLEMENT:-0}" = 1 ]; then echo '<plist><dict/></plist>'; else
      echo '<plist><dict><key>com.apple.security.personal-information.calendars</key><true/></dict></plist>'; fi ;;
esac
exit 0
STUB
cat > "$tools/xcrun" <<STUB
#!/bin/sh
printf 'xcrun %s\n' "\$*" >> "$calls"
exit 0
STUB
chmod +x "$tools/codesign" "$tools/xcrun"
secret_identity=ABCDEF0123456789ABCDEF0123456789ABCDEF01

if TEST_NO_ENTITLEMENT=1 PATH="$tools:$PATH" "$script" "$app" --output-directory "$out" \
  --identity "$secret_identity" > "$log" 2>&1; then
  echo "An app without the Calendar entitlement was packaged." >&2; exit 1
fi
grep -q 'Calendar entitlement' "$log"

: > "$calls"
PATH="$tools:$PATH" "$script" "$app" --output-directory "$out" --identity "$secret_identity" > "$log" 2>&1
grep -q -- "--sign $secret_identity --timestamp" "$calls"
if grep -q notarytool "$calls"; then echo "Notarization ran without being asked." >&2; exit 1; fi
if grep -q "$secret_identity" "$log"; then echo "The identity reached the output." >&2; exit 1; fi

: > "$calls"
PATH="$tools:$PATH" "$script" "$app" --output-directory "$out" --identity "$secret_identity" \
  --notarize synthetic-profile > "$log" 2>&1
grep -q 'notarytool submit .* --keychain-profile synthetic-profile --wait' "$calls"
grep -q 'stapler staple' "$calls"
grep -q 'stapler validate' "$calls"

echo "Disk image packaging checks passed."
