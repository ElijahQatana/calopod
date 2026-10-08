#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-release-test.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT

test_home="$test_root/home"
bundle_root="$test_root/bundle"
mkdir -p \
  "$test_home" \
  "$bundle_root/bin" \
  "$bundle_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS" \
  "$bundle_root/Scripts"
cp "$repository_root/Support/Release/install" "$bundle_root/install"
cp "$repository_root/Support/Release/uninstall" "$bundle_root/uninstall"
cp "$repository_root/Scripts/calopod-service.sh" "$bundle_root/Scripts/calopod-service.sh"
cp "$repository_root/Scripts/calopod-setup.sh" "$bundle_root/Scripts/calopod-setup.sh"
chmod 700 \
  "$bundle_root/install" \
  "$bundle_root/uninstall" \
  "$bundle_root/Scripts/calopod-service.sh" \
  "$bundle_root/Scripts/calopod-setup.sh"

write_payload() {
  exit_code=$1
  cat > "$bundle_root/bin/calopod" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
  echo 0.1.0
  exit 0
fi
exit $exit_code
EOF
  printf '#!/bin/sh\nexit %s\n' "$exit_code" > "$bundle_root/bin/calopod-agent"
  cat > "$bundle_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost" <<EOF
#!/bin/sh
if [ "\${1:-}" = --register-app ]; then exit 0; fi
exit $exit_code
EOF
  chmod 700 \
    "$bundle_root/bin/calopod" \
    "$bundle_root/bin/calopod-agent" \
    "$bundle_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"
}

write_checksums() {
  (
    CDPATH= cd -- "$bundle_root"
    find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file"
    done > SHA256SUMS
  )
}

printf '0.1.0\n' > "$bundle_root/VERSION"
printf 'developer-id-notarized-v1\n' > "$bundle_root/SIGNING"
write_payload 0
write_checksums

state_root="$test_home/Library/Application Support/Calopod"
mkdir -p "$state_root"
printf 'state-sentinel\n' > "$state_root/state.sqlite"
printf 'keychain-sentinel\n' > "$state_root/keychain-sentinel"

run_installer() {
  env \
    CALOPOD_RELEASE_TEST_MODE=1 \
    CALOPOD_RELEASE_TEST_HOME="$test_home" \
    "$bundle_root/install" \
      --interval-seconds 600 \
      --jitter-seconds 30 \
      --lookback-days 1 \
      --horizon-days 30
}

run_installer >/dev/null

service_root="$state_root/Service"
plist_path="$test_home/Library/LaunchAgents/pro.elijahquintana.calopod.agent.plist"
cli_link="$test_home/.local/bin/calopod"
setup_link="$test_home/.local/bin/calopod-setup"
uninstall_link="$test_home/.local/bin/calopod-uninstall"
[ -x "$service_root/bin/calopod" ]
[ -x "$service_root/bin/calopod-agent" ]
[ -x "$service_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost" ]
[ "$(cat "$service_root/release/VERSION")" = "0.1.0" ]
[ "$(cat "$service_root/release/SIGNING")" = "developer-id-notarized-v1" ]
[ -L "$cli_link" ]
[ "$(readlink "$cli_link")" = "$service_root/bin/calopod" ]
[ -L "$setup_link" ]
[ "$(readlink "$setup_link")" = "$service_root/release/calopod-setup.sh" ]
[ -L "$uninstall_link" ]
[ "$(readlink "$uninstall_link")" = "$service_root/release/uninstall" ]
[ "$(stat -f '%Lp' "$service_root")" = "700" ]
[ "$(stat -f '%Lp' "$service_root/release/VERSION")" = "600" ]

rm "$bundle_root/SIGNING"
write_checksums
if run_installer >/dev/null 2>&1; then
  echo "The release installer accepted an unsigned downgrade." >&2
  exit 1
fi
[ "$(cat "$service_root/release/SIGNING")" = "developer-id-notarized-v1" ]
printf 'developer-id-notarized-v1\n' > "$bundle_root/SIGNING"
write_checksums

write_payload 2
write_checksums
run_installer >/dev/null
[ "$(tail -n 1 "$service_root/bin/calopod-agent")" = "exit 2" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
[ -z "$(find "$test_home/.local/bin" -name '*.installing.*' -print -quit)" ]

printf 'corrupt\n' >> "$bundle_root/bin/calopod-agent"
if run_installer >/dev/null 2>&1; then
  echo "The release installer accepted a checksum mismatch." >&2
  exit 1
fi
[ "$(tail -n 1 "$service_root/bin/calopod-agent")" = "exit 2" ]
[ -z "$(find "$test_home/.local/bin" -name '*.installing.*' -print -quit)" ]

write_payload 3
write_checksums
if CALOPOD_SERVICE_TEST_FAILURE_POINT=after-service run_installer >/dev/null 2>&1; then
  echo "The release installer ignored an injected service failure." >&2
  exit 1
fi
[ "$(tail -n 1 "$service_root/bin/calopod-agent")" = "exit 2" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
[ -z "$(find "$test_home/.local/bin" -name '*.installing.*' -print -quit)" ]

env \
  CALOPOD_RELEASE_TEST_MODE=1 \
  CALOPOD_RELEASE_TEST_HOME="$test_home" \
  "$service_root/release/uninstall" >/dev/null

[ ! -e "$service_root" ]
[ ! -e "$plist_path" ]
[ ! -e "$cli_link" ]
[ ! -e "$setup_link" ]
[ ! -e "$uninstall_link" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
[ "$(cat "$state_root/keychain-sentinel")" = "keychain-sentinel" ]

echo "Release installer checks passed."
