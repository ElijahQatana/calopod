#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-service-test.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT

test_home="$test_root/home"
cli_source="$test_root/build/calopod"
agent_source="$test_root/build/calopod-agent"
host_source="$test_root/build/Calopod EventKit Host.app"
host_executable="$host_source/Contents/MacOS/CalopodEventKitHost"
release_source="$test_root/build/release"
mkdir -p "$test_home" "$(dirname "$agent_source")" "$(dirname "$host_executable")"
printf '#!/bin/sh\nexit 0\n' > "$cli_source"
printf '#!/bin/sh\nexit 0\n' > "$agent_source"
cat > "$host_executable" <<EOF
#!/bin/sh
[ "\$1" = --register-app ] || exit 64
printf '%s\n' "\$0" >> "$test_root/registered-apps"
EOF
mkdir -p "$release_source/Scripts"
printf '0.1.0\n' > "$release_source/VERSION"
printf 'synthetic checksums\n' > "$release_source/SHA256SUMS"
printf '#!/bin/sh\nexit 0\n' > "$release_source/uninstall"
printf '#!/bin/sh\nexit 0\n' > "$release_source/Scripts/calopod-service.sh"
printf '#!/bin/sh\nexit 0\n' > "$release_source/Scripts/calopod-setup.sh"
chmod 700 \
  "$cli_source" \
  "$agent_source" \
  "$host_executable" \
  "$release_source/uninstall" \
  "$release_source/Scripts/calopod-service.sh" \
  "$release_source/Scripts/calopod-setup.sh"

state_root="$test_home/Library/Application Support/Calopod"
mkdir -p "$state_root"
printf 'state-sentinel\n' > "$state_root/state.sqlite"
printf 'keychain-sentinel\n' > "$state_root/keychain-sentinel"

run_service() {
  env \
    CALOPOD_SERVICE_TEST_MODE=1 \
    CALOPOD_SERVICE_TEST_HOME="$test_home" \
    CALOPOD_SERVICE_TEST_CLI_SOURCE="$cli_source" \
    CALOPOD_SERVICE_TEST_AGENT_SOURCE="$agent_source" \
    CALOPOD_SERVICE_TEST_HOST_SOURCE="$host_source" \
    CALOPOD_SERVICE_RELEASE_SOURCE="$release_source" \
    "$repository_root/Scripts/calopod-service.sh" "$@"
}

run_service_with_failure() {
  failure_point=$1
  shift
  env \
    CALOPOD_SERVICE_TEST_MODE=1 \
    CALOPOD_SERVICE_TEST_HOME="$test_home" \
    CALOPOD_SERVICE_TEST_CLI_SOURCE="$cli_source" \
    CALOPOD_SERVICE_TEST_AGENT_SOURCE="$agent_source" \
    CALOPOD_SERVICE_TEST_HOST_SOURCE="$host_source" \
    CALOPOD_SERVICE_RELEASE_SOURCE="$release_source" \
    CALOPOD_SERVICE_TEST_FAILURE_POINT="$failure_point" \
    "$repository_root/Scripts/calopod-service.sh" "$@"
}

run_service install \
  --interval-seconds 600 \
  --jitter-seconds 30 \
  --lookback-days 1 \
  --horizon-days 30 >/dev/null

service_root="$state_root/Service"
plist_path="$test_home/Library/LaunchAgents/pro.elijahquintana.calopod.agent.plist"
installed_agent="$service_root/bin/calopod-agent"
installed_cli="$service_root/bin/calopod"
installed_host="$service_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"

[ -x "$installed_cli" ]
[ -x "$installed_agent" ]
[ -x "$installed_host" ]
[ "$(cat "$service_root/release/VERSION")" = "0.1.0" ]
[ -x "$service_root/release/uninstall" ]
[ -x "$service_root/release/calopod-service.sh" ]
[ -x "$service_root/release/calopod-setup.sh" ]
plutil -lint "$plist_path" >/dev/null
[ "$(plutil -extract Label raw "$plist_path")" = "pro.elijahquintana.calopod.agent" ]
[ "$(plutil -extract AssociatedBundleIdentifiers.0 raw "$plist_path")" = "pro.elijahquintana.calopod.eventkit-host" ]
[ "$(cat "$test_root/registered-apps")" = "$installed_host" ]
[ "$(plutil -extract ProgramArguments.0 raw "$plist_path")" = "$installed_agent" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_STATE_PATH raw "$plist_path")" = "$state_root/state.sqlite" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_EVENTKIT_HOST_APP raw "$plist_path")" = "$service_root/eventkit-host/Calopod EventKit Host.app" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "600" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_JITTER_SECONDS raw "$plist_path")" = "30" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_LOOKBACK_DAYS raw "$plist_path")" = "1" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_HORIZON_DAYS raw "$plist_path")" = "30" ]
[ "$(plutil -extract RunAtLoad raw "$plist_path")" = "true" ]
[ "$(plutil -extract KeepAlive raw "$plist_path")" = "true" ]
[ "$(plutil -extract ThrottleInterval raw "$plist_path")" = "30" ]
[ "$(plutil -extract KeepAlive raw "$plist_path")" = "true" ]
[ "$(stat -f '%Lp' "$plist_path")" = "600" ]
[ "$(stat -f '%Lp' "$service_root/logs/agent.stdout.log")" = "600" ]
[ "$(stat -f '%Lp' "$service_root/logs/agent.stderr.log")" = "600" ]

! plutil -extract EnvironmentVariables.CALOPOD_GOOGLE_CLIENT_ID raw "$plist_path" >/dev/null 2>&1
! plutil -extract EnvironmentVariables.CALOPOD_MICROSOFT_CLIENT_ID raw "$plist_path" >/dev/null 2>&1
! plutil -extract EnvironmentVariables.CALOPOD_GOOGLE_CLIENT_SECRET raw "$plist_path" >/dev/null 2>&1
(
  export CALOPOD_GOOGLE_CLIENT_ID=synthetic-google-id
  export CALOPOD_GOOGLE_CLIENT_SECRET=synthetic-google-secret
  export CALOPOD_MICROSOFT_CLIENT_ID=synthetic-microsoft-id
  export CALOPOD_MICROSOFT_TENANT=organizations
  run_service install \
    --interval-seconds 600 \
    --jitter-seconds 30 \
    --lookback-days 1 \
    --horizon-days 30 >/dev/null
)
[ "$(plutil -extract EnvironmentVariables.CALOPOD_GOOGLE_CLIENT_ID raw "$plist_path")" = "synthetic-google-id" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_GOOGLE_CLIENT_SECRET raw "$plist_path")" = "synthetic-google-secret" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_MICROSOFT_CLIENT_ID raw "$plist_path")" = "synthetic-microsoft-id" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_MICROSOFT_TENANT raw "$plist_path")" = "organizations" ]

printf '#!/bin/sh\nexit 2\n' > "$agent_source"
printf '#!/bin/sh\nexit 2\n' > "$cli_source"
chmod 700 "$cli_source"
chmod 700 "$agent_source"
run_service install \
  --interval-seconds 900 \
  --jitter-seconds 45 \
  --lookback-days 2 \
  --horizon-days 60 >/dev/null
[ "$(tail -n 1 "$installed_agent")" = "exit 2" ]
[ "$(tail -n 1 "$installed_cli")" = "exit 2" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "900" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]

printf '#!/bin/sh\nexit 70\n' > "$host_executable"
if run_service install \
  --interval-seconds 1200 \
  --jitter-seconds 60 \
  --lookback-days 3 \
  --horizon-days 90 >/dev/null 2>&1; then
  echo "The installer accepted a failed app association." >&2
  exit 1
fi
[ "$(tail -n 1 "$installed_agent")" = "exit 2" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "900" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
[ "$(cat "$state_root/keychain-sentinel")" = "keychain-sentinel" ]
printf '#!/bin/sh\nexit 0\n' > "$host_executable"

for failure_point in after-staging after-backup after-service after-plist; do
  printf '#!/bin/sh\nexit 3\n' > "$agent_source"
  chmod 700 "$agent_source"
  if run_service_with_failure "$failure_point" install \
    --interval-seconds 1200 \
    --jitter-seconds 60 \
    --lookback-days 3 \
    --horizon-days 90 >/dev/null 2>&1; then
    echo "The installer ignored an injected failure." >&2
    exit 1
  fi
  [ "$(tail -n 1 "$installed_agent")" = "exit 2" ]
  [ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "900" ]
  [ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
  [ "$(cat "$state_root/keychain-sentinel")" = "keychain-sentinel" ]
done

outside_host=$(mktemp -d "${TMPDIR:-/tmp}/calopod-outside-host.XXXXXX")
mkdir -p "$outside_host/Calopod EventKit Host.app/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$outside_host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"
chmod 700 "$outside_host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"
outside_error=$(env \
  CALOPOD_SERVICE_TEST_MODE=1 \
  CALOPOD_SERVICE_TEST_HOME="$test_home" \
  CALOPOD_SERVICE_TEST_CLI_SOURCE="$cli_source" \
  CALOPOD_SERVICE_TEST_AGENT_SOURCE="$agent_source" \
  CALOPOD_SERVICE_TEST_HOST_SOURCE="$outside_host/Calopod EventKit Host.app" \
  CALOPOD_SERVICE_RELEASE_SOURCE="$release_source" \
  "$repository_root/Scripts/calopod-service.sh" install \
  --interval-seconds 600 --jitter-seconds 30 --lookback-days 1 --horizon-days 30 2>&1 >/dev/null) && {
  echo "Test mode accepted a host outside the test directory." >&2
  rm -rf "$outside_host"
  exit 1
}
case "$outside_error" in
  *"outside the expected temporary directory"*) ;;
  *) echo "Unexpected test-mode failure: $outside_error" >&2; exit 1 ;;
esac
rm -rf "$outside_host"

if run_service install \
  --interval-seconds 0 \
  --jitter-seconds 30 \
  --lookback-days 1 \
  --horizon-days 30 >/dev/null 2>&1; then
  echo "The installer accepted an invalid interval." >&2
  exit 1
fi

run_service remove >/dev/null

[ ! -e "$service_root" ]
[ ! -e "$plist_path" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]
[ "$(cat "$state_root/keychain-sentinel")" = "keychain-sentinel" ]

echo "Service installer checks passed."
