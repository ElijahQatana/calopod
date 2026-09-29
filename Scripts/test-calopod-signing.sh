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
[ "$(grep -c -- '--check-notarization -R=notarized' "$call_log")" = 2 ]
[ "$(grep -c '^syspolicy distribution ' "$call_log")" = 1 ]
! grep -F "$identity" "$output_file" > /dev/null
! grep -F "$profile" "$output_file" > /dev/null

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
