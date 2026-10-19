#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
Usage:
  Scripts/sign-calopod-release.sh \
    --bundle PATH \
    --archive PATH \
    --checksum PATH \
    --signing-identity SHA1 \
    --notary-profile NAME
EOF
}

require_absolute_path() {
  case "$1" in
    /*) ;;
    *) fail "A release signing path is not absolute." 78 ;;
  esac
}

bundle_path=""
archive_path=""
checksum_path=""
signing_identity=""
notary_profile=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || fail "--bundle requires a value." 64
      bundle_path=$2
      shift 2
      ;;
    --archive)
      [ "$#" -ge 2 ] || fail "--archive requires a value." 64
      archive_path=$2
      shift 2
      ;;
    --checksum)
      [ "$#" -ge 2 ] || fail "--checksum requires a value." 64
      checksum_path=$2
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
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "Unknown release-signing option: $1" 64 ;;
  esac
done

require_absolute_path "$bundle_path"
require_absolute_path "$archive_path"
require_absolute_path "$checksum_path"
[ -d "$bundle_path" ] || fail "The staged release bundle is missing." 66
[ ! -L "$bundle_path" ] || fail "The staged release bundle cannot be a symbolic link." 78
[ ! -e "$archive_path" ] || fail "The signed release archive already exists." 73
[ ! -e "$checksum_path" ] || fail "The signed release checksum already exists." 73
[ "$checksum_path" = "$archive_path.sha256" ] \
  || fail "The signed release checksum path is invalid." 78
archive_root=$(dirname "$archive_path")
[ -d "$archive_root" ] || fail "The release output directory is missing." 66
archive_root=$(CDPATH= cd -- "$archive_root" && pwd -P)
[ "$(dirname "$checksum_path")" = "$archive_root" ] \
  || fail "The signed release outputs must share one directory." 78

printf '%s\n' "$signing_identity" | grep -Eq '^[0-9A-Fa-f]{40}$' \
  || fail "The signing identity must be a certificate SHA-1 hash." 64
printf '%s\n' "$notary_profile" | grep -Eq '^[A-Za-z0-9._-]+$' \
  || fail "The notary profile name is invalid." 64

cli_path="$bundle_path/bin/calopod"
agent_path="$bundle_path/bin/calopod-agent"
host_path="$bundle_path/eventkit-host/Calopod EventKit Host.app"
host_executable="$host_path/Contents/MacOS/CalopodEventKitHost"
for executable in "$cli_path" "$agent_path" "$host_executable"; do
  [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] \
    || fail "The staged release executable layout is invalid." 66
done
[ -f "$host_path/Contents/Info.plist" ] \
  || fail "The staged EventKit host is incomplete." 66
[ ! -e "$bundle_path/SIGNING" ] \
  || fail "The staged release already contains signing metadata." 73

test_mode=${CALOPOD_RELEASE_SIGNING_TEST_MODE:-0}
if [ "$test_mode" = "1" ]; then
  case "$bundle_path" in
    */calopod-signing-test.*/Calopod-*-macos-arm64) ;;
    *) fail "The signing test bundle is outside the expected temporary directory." 78 ;;
  esac
  security_tool=${CALOPOD_RELEASE_TEST_SECURITY_TOOL:-}
  codesign_tool=${CALOPOD_RELEASE_TEST_CODESIGN_TOOL:-}
  xcrun_tool=${CALOPOD_RELEASE_TEST_XCRUN_TOOL:-}
  syspolicy_tool=${CALOPOD_RELEASE_TEST_SYSPOLICY_TOOL:-}
  ditto_tool=${CALOPOD_RELEASE_TEST_DITTO_TOOL:-}
  for tool in "$security_tool" "$codesign_tool" "$xcrun_tool" "$syspolicy_tool" "$ditto_tool"; do
    require_absolute_path "$tool"
    [ -x "$tool" ] || fail "A release signing test tool is unavailable." 78
  done
else
  security_tool=/usr/bin/security
  codesign_tool=/usr/bin/codesign
  xcrun_tool=/usr/bin/xcrun
  syspolicy_tool=/usr/bin/syspolicy_check
  ditto_tool=/usr/bin/ditto
fi

temporary_root=$(mktemp -d "$archive_root/.calopod-signing.XXXXXX") \
  || fail "Could not create the private signing workspace." 74
chmod 700 "$temporary_root"
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

identity_file="$temporary_root/identities.txt"
: > "$identity_file"
chmod 600 "$identity_file"
"$security_tool" find-identity -v -p codesigning > "$identity_file" 2>/dev/null \
  || fail "The code-signing identities could not be inspected." 69
awk -v expected="$signing_identity" '
  $2 == expected && /Developer ID Application/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$identity_file" || fail "The selected Developer ID Application identity is unavailable." 77

. "$repository_root/Scripts/calopod-codesign.sh"
sign_item() {
  calopod_sign_item "$codesign_tool" "$signing_identity" "$@" \
    || fail "A release executable could not be signed." 65
}

sign_item "$cli_path"
sign_item "$agent_path"
sign_item "$host_path" --entitlements "$repository_root/Support/EventKitHost/Entitlements.plist"

host_entitlements="$temporary_root/host-entitlements.plist"
"$codesign_tool" -d --entitlements :- "$host_path" > "$host_entitlements" 2>/dev/null \
  || fail "The signed Calendar host entitlements could not be inspected." 65
[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.personal-information\.calendars' raw -o - "$host_entitlements" 2>/dev/null)" = true ] \
  || fail "The signed Calendar host is missing its Calendar entitlement." 65
"$codesign_tool" --verify --strict "$cli_path" > /dev/null 2>&1 \
  || fail "The release CLI signature is invalid." 65
"$codesign_tool" --verify --strict "$agent_path" > /dev/null 2>&1 \
  || fail "The release agent signature is invalid." 65
"$codesign_tool" --verify --deep --strict "$host_path" > /dev/null 2>&1 \
  || fail "The release EventKit host signature is invalid." 65

printf 'developer-id-notarized-v1\n' > "$bundle_path/SIGNING"
chmod 600 "$bundle_path/SIGNING"

write_checksums() {
  (
    CDPATH= cd -- "$bundle_path"
    find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file"
    done > SHA256SUMS
    chmod 600 SHA256SUMS
    shasum -a 256 -c SHA256SUMS > /dev/null
  )
}

write_checksums
submission_archive="$temporary_root/submission.zip"
"$ditto_tool" -c -k --sequesterRsrc --keepParent \
  "$bundle_path" "$submission_archive" > /dev/null 2>&1 \
  || fail "The notarization archive could not be created." 74

notary_result="$temporary_root/notary-result.json"
: > "$notary_result"
chmod 600 "$notary_result"
"$xcrun_tool" notarytool submit "$submission_archive" \
  --keychain-profile "$notary_profile" \
  --wait \
  --output-format json > "$notary_result" 2>&1 \
  || fail "The release could not be submitted for notarization." 69
notary_status=$(/usr/bin/plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)
[ "$notary_status" = "Accepted" ] \
  || fail "The release was not accepted by the notarization service." 65
submission_id=$(/usr/bin/plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)
[ -n "$submission_id" ] || fail "The notarization result was incomplete." 65

notary_log="$temporary_root/notary-log.json"
"$xcrun_tool" notarytool log \
  --keychain-profile "$notary_profile" \
  "$submission_id" "$notary_log" > /dev/null 2>&1 \
  || fail "The notarization log could not be checked." 69
chmod 600 "$notary_log"
notary_issues=$(/usr/bin/plutil -extract issues json -o - "$notary_log" 2>/dev/null \
  | tr -d '[:space:]' || true)
notary_issues_null=false
if /usr/bin/plutil -p "$notary_log" 2>/dev/null \
  | grep -Eq '^[[:space:]]*"issues" => <null>[[:space:]]*$'; then
  notary_issues_null=true
fi
if [ "$notary_issues" != "[]" ] && [ "$notary_issues_null" != true ]; then
  fail "The notarization log contains issues that require review." 65
fi

"$xcrun_tool" stapler staple -q "$host_path" > /dev/null 2>&1 \
  || fail "The EventKit host notarization ticket could not be stapled." 65
"$xcrun_tool" stapler validate -q "$host_path" > /dev/null 2>&1 \
  || fail "The EventKit host notarization ticket is invalid." 65

for executable in "$cli_path" "$agent_path"; do
  "$codesign_tool" --verify --strict --check-notarization -R=notarized \
    "$executable" > /dev/null 2>&1 \
    || fail "A release command failed its notarization check." 65
done
"$syspolicy_tool" distribution "$host_path" > /dev/null 2>&1 \
  || fail "The release EventKit host failed system policy validation." 65

write_checksums
"$ditto_tool" -c -k --sequesterRsrc --keepParent \
  "$bundle_path" "$archive_path" > /dev/null 2>&1 \
  || fail "The signed release archive could not be created." 74
(
  CDPATH= cd -- "$archive_root"
  shasum -a 256 "$(basename "$archive_path")" > "$(basename "$checksum_path")"
  shasum -a 256 -c "$(basename "$checksum_path")" > /dev/null
)
chmod 600 "$checksum_path"

trap - EXIT HUP INT TERM
cleanup
echo "Signed and notarized the Calopod release."
