#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
output_directory="$repository_root/.build/releases"

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
Usage:
  Scripts/build-calopod-release.sh [--output-directory PATH] \
    [--signing-identity SHA1 --notary-profile NAME] [--dmg]

--dmg also builds the Mac app and a drag-to-install disk image next to the ZIP. The image is
signed with the same identity but never notarized here; see docs/releasing.md.
EOF
}

signing_identity=""
notary_profile=""
build_dmg=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-directory)
      [ "$#" -ge 2 ] || fail "--output-directory requires a value." 64
      output_directory=$2
      shift 2
      ;;
    --signing-identity)
      [ "$#" -ge 2 ] || fail "--signing-identity requires a value." 64
      signing_identity=$2
      shift 2
      ;;
    --notary-profile)
      [ "$#" -ge 2 ] || fail "--notary-profile requires a value." 64
      notary_profile=$2
      shift 2
      ;;
    --dmg)
      build_dmg=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "Unknown release-build option: $1" 64 ;;
  esac
done
if { [ -n "$signing_identity" ] && [ -z "$notary_profile" ]; } \
  || { [ -z "$signing_identity" ] && [ -n "$notary_profile" ]; }; then
  fail "Developer ID signing and notarization options must be provided together." 64
fi
distribution_build=0
if [ -n "$signing_identity" ]; then
  distribution_build=1
fi

case "$output_directory" in
  /*) ;;
  *) output_directory="$repository_root/$output_directory" ;;
esac
install -d -m 700 "$output_directory"
output_directory=$(CDPATH= cd -- "$output_directory" && pwd -P)

version=$(sed -n '1p' "$repository_root/VERSION")
[ -n "$version" ] || fail "VERSION is empty." 65
[ "$(wc -l < "$repository_root/VERSION" | tr -d ' ')" = "1" ] \
  || fail "VERSION must contain one line." 65
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' \
  || fail "VERSION is invalid." 65
[ "$(uname -m)" = "arm64" ] || fail "This preview bundle requires an Apple Silicon build host." 69

bundle_name="Calopod-$version-macos-arm64"
bundle_path="$output_directory/$bundle_name"
archive_path="$output_directory/$bundle_name.zip"
archive_checksum_path="$archive_path.sha256"
[ ! -e "$bundle_path" ] || fail "The versioned release directory already exists." 73
[ ! -e "$archive_path" ] || fail "The versioned release archive already exists." 73
[ ! -e "$archive_checksum_path" ] || fail "The release archive checksum already exists." 73

swift build \
  --package-path "$repository_root" \
  --configuration release \
  --product calopod
swift build \
  --package-path "$repository_root" \
  --configuration release \
  --product calopod-agent
CALOPOD_BUILD_CONFIGURATION=release \
  "$repository_root/Scripts/build-eventkit-host.sh"
binary_root=$(swift build \
  --package-path "$repository_root" \
  --configuration release \
  --show-bin-path)

staging_root=$(mktemp -d "$output_directory/.calopod-release.XXXXXX") \
  || fail "Could not create the release staging directory." 74
staged_bundle="$staging_root/$bundle_name"
cleanup_staging() {
  [ ! -d "$staging_root" ] || rm -rf "$staging_root"
}
trap cleanup_staging EXIT HUP INT TERM

install -d -m 700 \
  "$staged_bundle/bin" \
  "$staged_bundle/eventkit-host" \
  "$staged_bundle/Scripts"
install -m 700 "$binary_root/calopod" "$staged_bundle/bin/calopod"
install -m 700 "$binary_root/calopod-agent" "$staged_bundle/bin/calopod-agent"
ditto \
  "$repository_root/.build/eventkit-host/Calopod EventKit Host.app" \
  "$staged_bundle/eventkit-host/Calopod EventKit Host.app"
install -m 700 "$repository_root/Support/Release/install" "$staged_bundle/install"
install -m 700 "$repository_root/Support/Release/uninstall" "$staged_bundle/uninstall"
install -m 700 \
  "$repository_root/Scripts/calopod-service.sh" \
  "$staged_bundle/Scripts/calopod-service.sh"
install -m 700 \
  "$repository_root/Scripts/calopod-setup.sh" \
  "$staged_bundle/Scripts/calopod-setup.sh"
install -m 600 "$repository_root/Support/Release/README.md" "$staged_bundle/README.md"
install -m 600 "$repository_root/VERSION" "$staged_bundle/VERSION"

host_plist="$staged_bundle/eventkit-host/Calopod EventKit Host.app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$host_plist"
[ "$("$staged_bundle/bin/calopod" --version)" = "$version" ] \
  || fail "The CLI version does not match VERSION." 65
[ "$(plutil -extract CFBundleShortVersionString raw "$host_plist")" = "$version" ] \
  || fail "The EventKit host version does not match VERSION." 65
[ "$(lipo -archs "$staged_bundle/bin/calopod")" = "arm64" ] \
  || fail "The CLI is not an arm64 release binary." 65
[ "$(lipo -archs "$staged_bundle/bin/calopod-agent")" = "arm64" ] \
  || fail "The agent is not an arm64 release binary." 65
[ "$(lipo -archs "$staged_bundle/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost")" = "arm64" ] \
  || fail "The EventKit host is not an arm64 release binary." 65

staged_archive="$staging_root/$bundle_name.zip"
staged_archive_checksum="$staged_archive.sha256"
if [ "$distribution_build" = "1" ]; then
  "$repository_root/Scripts/sign-calopod-release.sh" \
    --bundle "$staged_bundle" \
    --archive "$staged_archive" \
    --checksum "$staged_archive_checksum" \
    --signing-identity "$signing_identity" \
    --notary-profile "$notary_profile"
else
  codesign --force --sign - "$staged_bundle/bin/calopod" >/dev/null 2>&1
  codesign --force --sign - "$staged_bundle/bin/calopod-agent" >/dev/null 2>&1
  codesign --force --sign - \
    "$staged_bundle/eventkit-host/Calopod EventKit Host.app" >/dev/null 2>&1
  codesign --verify --strict "$staged_bundle/bin/calopod"
  codesign --verify --strict "$staged_bundle/bin/calopod-agent"
  codesign --verify --deep --strict \
    "$staged_bundle/eventkit-host/Calopod EventKit Host.app"

  (
    CDPATH= cd -- "$staged_bundle"
    find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file"
    done > SHA256SUMS
    chmod 600 SHA256SUMS
    shasum -a 256 -c SHA256SUMS >/dev/null
  )
  (
    CDPATH= cd -- "$staging_root"
    ditto -c -k --sequesterRsrc --keepParent "$bundle_name" "$bundle_name.zip"
    shasum -a 256 "$bundle_name.zip" > "$bundle_name.zip.sha256"
  )
fi

mv "$staged_bundle" "$bundle_path"
staged_bundle=""
mv "$staged_archive" "$archive_path"
mv "$staged_archive_checksum" "$archive_checksum_path"
trap - EXIT HUP INT TERM
rm -rf "$staging_root"
staging_root=""

echo "Built $bundle_name.zip and its SHA-256 checksum."

if [ "$build_dmg" = "1" ]; then
  if [ "$distribution_build" = "1" ]; then
    CALOPOD_BUILD_CONFIGURATION=release CALOPOD_SIGN_IDENTITY="$signing_identity" \
      "$repository_root/Scripts/build-calopod-mac-app.sh"
    "$repository_root/Scripts/make-calopod-dmg.sh" \
      --output-directory "$output_directory" --identity "$signing_identity"
  else
    CALOPOD_BUILD_CONFIGURATION=release CALOPOD_SIGN_IDENTITY= \
      "$repository_root/Scripts/build-calopod-mac-app.sh"
    "$repository_root/Scripts/make-calopod-dmg.sh" \
      --output-directory "$output_directory" --identity "" --allow-adhoc
  fi
fi
