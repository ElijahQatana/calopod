#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-signing-test.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT

bundle_name=Calopod-0.1.0-macos-arm64
bundle_path="$test_root/$bundle_name"
archive_path="$test_root/$bundle_name.zip"
checksum_path="$archive_path.sha256"
tool_root="$test_root/tools"
call_log="$test_root/calls"
mkdir -p \
  "$bundle_path/bin" \
  "$bundle_path/eventkit-host/Calopod EventKit Host.app/Contents/MacOS" \
  "$tool_root"
for executable in \
  "$bundle_path/bin/calopod" \
  "$bundle_path/bin/calopod-agent" \
  "$bundle_path/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"; do
  printf '#!/bin/sh\nexit 0\n' > "$executable"
  chmod 700 "$executable"
done
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' \
  > "$bundle_path/eventkit-host/Calopod EventKit Host.app/Contents/Info.plist"

identity=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
profile=synthetic-notary-profile

cat > "$tool_root/security" <<EOF
#!/bin/sh
printf '  1) $identity "Developer ID Application: Example Company (EXAMPLE123)"\n'
EOF

cat > "$tool_root/codesign" <<EOF
#!/bin/sh
printf 'codesign %s\n' "\$*" >> "$call_log"
if [ "\$1" = -d ] && [ "\$2" = --entitlements ]; then
  if [ "\${CALOPOD_RELEASE_TEST_OMIT_CALENDAR_ENTITLEMENT:-0}" = 1 ]; then
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>'
  else
    cat "$repository_root/Support/EventKitHost/Entitlements.plist"
  fi
fi
exit 0
EOF

cat > "$tool_root/syspolicy_check" <<EOF
#!/bin/sh
printf 'syspolicy %s\n' "\$*" >> "$call_log"
exit 0
EOF

cat > "$tool_root/ditto" <<EOF
#!/bin/sh
for argument in "\$@"; do output=\$argument; done
printf 'synthetic archive\n' > "\$output"
EOF

cat > "$tool_root/xcrun" <<EOF
#!/bin/sh
printf 'xcrun %s\n' "\$*" >> "$call_log"
if [ "\$1" = notarytool ] && [ "\$2" = submit ]; then
  printf '%s\n' '{"id":"00000000-0000-0000-0000-000000000000","status":"Accepted"}'
elif [ "\$1" = notarytool ] && [ "\$2" = log ]; then
  for argument in "\$@"; do output=\$argument; done
  printf '%s\n' '{"issues":null}' > "\$output"
elif [ "\$1" = stapler ] && [ "\$2" = staple ]; then
  mkdir -p "$bundle_path/eventkit-host/Calopod EventKit Host.app/Contents/_CodeSignature"
  printf 'synthetic ticket\n' \
    > "$bundle_path/eventkit-host/Calopod EventKit Host.app/Contents/_CodeSignature/CodeResources"
fi
exit 0
EOF
chmod 700 "$tool_root"/*

output_file="$test_root/output"
if env \
  CALOPOD_RELEASE_SIGNING_TEST_MODE=1 \
  CALOPOD_RELEASE_TEST_OMIT_CALENDAR_ENTITLEMENT=1 \
  CALOPOD_RELEASE_TEST_SECURITY_TOOL="$tool_root/security" \
  CALOPOD_RELEASE_TEST_CODESIGN_TOOL="$tool_root/codesign" \
  CALOPOD_RELEASE_TEST_XCRUN_TOOL="$tool_root/xcrun" \
  CALOPOD_RELEASE_TEST_SYSPOLICY_TOOL="$tool_root/syspolicy_check" \
  CALOPOD_RELEASE_TEST_DITTO_TOOL="$tool_root/ditto" \
  "$repository_root/Scripts/sign-calopod-release.sh" \
    --bundle "$bundle_path" \
    --archive "$archive_path" \
    --checksum "$checksum_path" \
    --signing-identity "$identity" \
    --notary-profile "$profile" > "$output_file" 2>&1; then
  echo "The signing helper accepted a host without Calendar access entitlement." >&2
  exit 1
fi
[ ! -e "$archive_path" ]
! grep 'notarytool submit' "$call_log" > /dev/null
: > "$call_log"

env \
  CALOPOD_RELEASE_SIGNING_TEST_MODE=1 \
  CALOPOD_RELEASE_TEST_SECURITY_TOOL="$tool_root/security" \
  CALOPOD_RELEASE_TEST_CODESIGN_TOOL="$tool_root/codesign" \
  CALOPOD_RELEASE_TEST_XCRUN_TOOL="$tool_root/xcrun" \
  CALOPOD_RELEASE_TEST_SYSPOLICY_TOOL="$tool_root/syspolicy_check" \
  CALOPOD_RELEASE_TEST_DITTO_TOOL="$tool_root/ditto" \
  "$repository_root/Scripts/sign-calopod-release.sh" \
    --bundle "$bundle_path" \
    --archive "$archive_path" \
    --checksum "$checksum_path" \
    --signing-identity "$identity" \
    --notary-profile "$profile" > "$output_file"

[ -f "$archive_path" ]
[ -f "$checksum_path" ]
[ "$(cat "$bundle_path/SIGNING")" = developer-id-notarized-v1 ]
(CDPATH= cd -- "$bundle_path" && shasum -a 256 -c SHA256SUMS > /dev/null)
(CDPATH= cd -- "$test_root" && shasum -a 256 -c "$(basename "$checksum_path")" > /dev/null)
[ "$(grep -c -- '--options runtime --timestamp' "$call_log")" = 3 ]
[ "$(grep -c -- '--entitlements' "$call_log")" = 4 ]
grep -- '--timestamp --entitlements .*Calopod EventKit Host.app$' "$call_log" > /dev/null
grep -- "--timestamp --entitlements $repository_root/Support/Mac/Entitlements.plist $bundle_path/bin/calopod\$" "$call_log" > /dev/null
grep -- "--timestamp --entitlements $repository_root/Support/Mac/Entitlements.plist $bundle_path/bin/calopod-agent\$" "$call_log" > /dev/null
[ "$(grep -c -- '--check-notarization -R=notarized' "$call_log")" = 2 ]
[ "$(grep -c '^syspolicy distribution ' "$call_log")" = 1 ]
! grep -F "$identity" "$output_file" > /dev/null
! grep -F "$profile" "$output_file" > /dev/null

# The local build signs through the same function as the release.
: > "$call_log"
(
  . "$repository_root/Scripts/calopod-codesign.sh"
  calopod_sign_item "$tool_root/codesign" "$identity" /example/item --entitlements /example/e.plist
  calopod_sign_item "$tool_root/codesign" - /example/adhoc
)
[ "$(sed -n 1p "$call_log")" = "codesign --force --sign $identity --options runtime --timestamp --entitlements /example/e.plist /example/item" ]
[ "$(sed -n 2p "$call_log")" = "codesign --force --sign - /example/adhoc" ]
for script in build-calopod-mac-app.sh build-eventkit-host.sh sign-calopod-release.sh; do
  grep -q 'calopod-codesign.sh' "$repository_root/Scripts/$script"
done
! grep -n '^codesign --force' "$repository_root/Scripts/build-calopod-mac-app.sh" "$repository_root/Scripts/build-eventkit-host.sh"
grep -q -- '--verify --strict --deep' "$repository_root/Scripts/build-calopod-mac-app.sh"
grep -q -- 'Entitlements.plist' "$repository_root/Scripts/build-calopod-mac-app.sh"

# The app, the agent and the command carry the Calendar entitlement, and the build prints it for the app.
grep -q 'outer_entitlements="$repository_root/Support/Mac/Entitlements.plist"' "$repository_root/Scripts/build-calopod-mac-app.sh"
grep -q -- '--entitlements "$outer_entitlements"' "$repository_root/Scripts/build-calopod-mac-app.sh"
for item in '"$contents_root/MacOS/calopod-agent"' '"$contents_root/MacOS/calopod"' '"$bundle_root"'; do
  grep -qF "sign_outer $item" "$repository_root/Scripts/build-calopod-mac-app.sh"
done
signed_app="$test_root/Calopod.app"
mkdir -p "$signed_app"
shown=$(
  . "$repository_root/Scripts/calopod-codesign.sh"
  entitlements_tool="$test_root/show-codesign"
  printf '#!/bin/sh\n[ "$1" = -d ] && cat "%s"\nexit 0\n' "$repository_root/Support/Mac/Entitlements.plist" > "$entitlements_tool"
  chmod 700 "$entitlements_tool"
  calopod_show_signature "$entitlements_tool" "$signed_app"
)
printf '%s\n' "$shown" | grep -q '^    com.apple.security.personal-information.calendars$'

if "$repository_root/Scripts/build-calopod-release.sh" \
  --output-directory "$test_root/unpaired-build" \
  --signing-identity "$identity" > /dev/null 2>&1; then
  echo "The release builder accepted incomplete notarization options." >&2
  exit 1
fi

if env \
  CALOPOD_RELEASE_SIGNING_TEST_MODE=1 \
  CALOPOD_RELEASE_TEST_SECURITY_TOOL="$tool_root/security" \
  CALOPOD_RELEASE_TEST_CODESIGN_TOOL="$tool_root/codesign" \
  CALOPOD_RELEASE_TEST_XCRUN_TOOL="$tool_root/xcrun" \
  CALOPOD_RELEASE_TEST_SYSPOLICY_TOOL="$tool_root/syspolicy_check" \
  CALOPOD_RELEASE_TEST_DITTO_TOOL="$tool_root/ditto" \
  "$repository_root/Scripts/sign-calopod-release.sh" \
    --bundle "$bundle_path" \
    --archive "$archive_path" \
    --checksum "$checksum_path" \
    --signing-identity not-a-hash \
    --notary-profile "$profile" > /dev/null 2>&1; then
  echo "The signing helper accepted an invalid identity selector." >&2
  exit 1
fi

echo "Release signing checks passed."
