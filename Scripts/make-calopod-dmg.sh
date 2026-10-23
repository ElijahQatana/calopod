#!/bin/sh

set -eu
umask 022

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
dmg_support="$repository_root/Scripts/dmg"
calendar_key=com.apple.security.personal-information.calendars

usage() {
  cat <<'EOT'
Usage:
  Scripts/make-calopod-dmg.sh [APP] [--output-directory PATH] [--identity NAME]
                              [--notarize PROFILE] [--allow-adhoc]

APP defaults to .build/mac-app/Calopod.app and must be signed with the hardened runtime and
the Calendar entitlement. The image goes to dist/Calopod.dmg with a .sha256 file.
--identity signs the image itself and defaults to CALOPOD_SIGN_IDENTITY.
--notarize PROFILE submits the image with that notarytool keychain profile and staples it.
--allow-adhoc packages an unsigned or ad hoc app for local testing only.
EOT
}

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

# Print repo paths relative to the repo and anything else by name only.
shown() {
  case "$1" in
    "$repository_root"/*) printf '%s\n' "${1#"$repository_root"/}" ;;
    *) basename "$1" ;;
  esac
}

app_path=""
output_directory="$repository_root/dist"
identity=${CALOPOD_SIGN_IDENTITY:-}
notary_profile=""
allow_adhoc=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-directory)
      [ "$#" -ge 2 ] || fail "--output-directory requires a value." 64
      output_directory=$2
      shift 2
      ;;
    --identity)
      [ "$#" -ge 2 ] || fail "--identity requires a value." 64
      identity=$2
      shift 2
      ;;
    --notarize)
      [ "$#" -ge 2 ] || fail "--notarize requires a keychain profile name." 64
      notary_profile=$2
      shift 2
      ;;
    --allow-adhoc)
      allow_adhoc=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) fail "Unknown option: $1" 64 ;;
    *)
      [ -z "$app_path" ] || fail "Only one app path is accepted." 64
      app_path=$1
      shift
      ;;
  esac
done
[ -n "$app_path" ] || app_path="$repository_root/.build/mac-app/Calopod.app"
[ "$identity" != "-" ] || identity=""
[ -d "$app_path" ] || fail "$(shown "$app_path") was not found. Build it with Scripts/build-calopod-mac-app.sh." 66
app_path=$(CDPATH= cd -- "$app_path" && pwd -P)
[ -z "$notary_profile" ] || [ -n "$identity" ] \
  || fail "--notarize needs a signed image. Pass --identity or set CALOPOD_SIGN_IDENTITY." 64

info_plist="$app_path/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist" 2>/dev/null) \
  || fail "Could not read the app version from its Info.plist." 65
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' \
  || fail "The app version is not a release version." 65
app_name=$(basename "$app_path" .app)

# --- Check the app's signature before anything is packaged. ---
helper_path="$app_path/Contents/MacOS/eventkit-host/Calopod EventKit Host.app"
problems=""
add_problem() { problems="$problems  - $1
"; }
adhoc=0
if ! codesign --verify --deep --strict "$app_path" > /dev/null 2>&1; then
  add_problem "the app has no valid signature (codesign --verify --deep --strict failed)"
  adhoc=1
else
  details=$(codesign -dvv "$app_path" 2>&1 || true)
  printf '%s\n' "$details" | grep -q '^Authority=Developer ID Application' && developer_id=1 || developer_id=0
  [ "$developer_id" = 1 ] || { add_problem "the app is not signed with a Developer ID Application certificate"; adhoc=1; }
fi
if [ "$adhoc" = 0 ]; then
  for item in "$app_path" "$helper_path"; do
    label=$(basename "$item")
    [ -d "$item" ] || { add_problem "$label is missing"; continue; }
    codesign -dvv "$item" 2>&1 | grep -Eq 'flags=[^ ]*\(.*runtime' \
      || add_problem "$label does not have the hardened runtime"
    codesign -d --entitlements :- "$item" 2>/dev/null | grep -q "$calendar_key" \
      || add_problem "$label does not have the Calendar entitlement"
  done
fi
if [ -n "$problems" ]; then
  if [ "$allow_adhoc" = 1 ]; then
    echo "Warning: packaging an app that is not release-signed (--allow-adhoc). Do not share this image." >&2
  else
    printf 'Refusing to package %s:\n%s' "$(shown "$app_path")" "$problems" >&2
    echo "Build a signed app with CALOPOD_SIGN_IDENTITY set, or pass --allow-adhoc for a local test." >&2
    exit 65
  fi
fi

# --- Tooling and background art. ---
build_root="$repository_root/.build/dmg"
venv="$repository_root/.build/dmg-venv"
mkdir -p "$build_root"
if [ ! -x "$venv/bin/dmgbuild" ]; then
  echo "Installing dmgbuild into .build/dmg-venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --require-hashes -r "$dmg_support/requirements.txt" \
    || fail "Could not install dmgbuild." 69
fi
art_root=$(mktemp -d "$build_root/art.XXXXXX")
trap 'rm -rf "$art_root"' EXIT HUP INT TERM
swift "$dmg_support/make-background.swift" "$dmg_support/layout.json" "$art_root" || fail "Could not draw the background." 65

# --- Build the image. ---
icon_name=$(plutil -extract CFBundleIconFile raw -o - "$info_plist" 2>/dev/null || true)
icon_file=""
if [ -n "$icon_name" ]; then
  for candidate in "$app_path/Contents/Resources/$icon_name" "$app_path/Contents/Resources/$icon_name.icns"; do
    [ -f "$candidate" ] && icon_file=$candidate && break
  done
fi
[ -n "$icon_file" ] || echo "Warning: the app has no icon file, so the volume gets the default icon." >&2

case "$output_directory" in
  /*) ;;
  *) output_directory="$repository_root/$output_directory" ;;
esac
mkdir -p "$output_directory"
output_directory=$(CDPATH= cd -- "$output_directory" && pwd -P)
dmg_name="$app_name.dmg"
dmg_path="$output_directory/$dmg_name"
rm -f "$dmg_path" "$dmg_path.sha256"

set -- -s "$dmg_support/settings.py" -D "app=$app_path" -D "background=$art_root/background.png" \
  -D "layout=$dmg_support/layout.json"
[ -z "$icon_file" ] || set -- "$@" -D "icon=$icon_file"
# hdiutil prints deprecation notices on every call; show the output only on failure.
"$venv/bin/dmgbuild" "$@" "$app_name" "$dmg_path" > "$art_root/dmgbuild.log" 2>&1 \
  || { cat "$art_root/dmgbuild.log" >&2; fail "dmgbuild failed." 70; }

# --- Sign and verify. ---
if [ -n "$identity" ]; then
  echo "Signing the image."
  codesign --force --sign "$identity" --timestamp "$dmg_path" > /dev/null 2>&1 \
    || fail "Could not sign the image." 65
  codesign --verify --strict "$dmg_path" > /dev/null 2>&1 \
    || fail "The image signature did not verify." 65
else
  echo "Note: the image is not signed (no identity given)."
fi
hdiutil verify -quiet "$dmg_path" > /dev/null || fail "hdiutil could not verify the image." 70

# --- Notarize only when asked. ---
if [ -n "$notary_profile" ]; then
  echo "Submitting for notarization and waiting. This can take a few minutes."
  xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait \
    || fail "Notarization did not succeed." 65
  xcrun stapler staple "$dmg_path" > /dev/null || fail "Could not staple the ticket." 65
  xcrun stapler validate "$dmg_path" > /dev/null || fail "The stapled ticket did not validate." 65
  echo "Notarized and stapled."
fi

(
  CDPATH= cd -- "$output_directory"
  shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)

echo "Built $(shown "$dmg_path") and its SHA-256 checksum."
if [ -z "$notary_profile" ]; then
  cat <<EOT
Not notarized. With your notarytool keychain profile, run:
  xcrun notarytool submit $(shown "$dmg_path") --keychain-profile PROFILE --wait
  xcrun stapler staple $(shown "$dmg_path")
  xcrun stapler validate $(shown "$dmg_path")
or run this script again with --notarize PROFILE.
EOT
fi
