#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-service-test.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT

test_home="$test_root/home"
agent_source="$test_root/build/calopod-agent"
host_source="$test_root/build/Calopod EventKit Host.app"
host_executable="$host_source/Contents/MacOS/CalopodEventKitHost"
mkdir -p "$test_home" "$(dirname "$agent_source")" "$(dirname "$host_executable")"
printf '#!/bin/sh\nexit 0\n' > "$agent_source"
printf '#!/bin/sh\nexit 0\n' > "$host_executable"
chmod 700 "$agent_source" "$host_executable"

state_root="$test_home/Library/Application Support/Calopod"
mkdir -p "$state_root"
printf 'state-sentinel\n' > "$state_root/state.sqlite"
printf 'keychain-sentinel\n' > "$state_root/keychain-sentinel"

run_service() {
  env \
    CALOPOD_SERVICE_TEST_MODE=1 \
    CALOPOD_SERVICE_TEST_HOME="$test_home" \
    CALOPOD_SERVICE_TEST_AGENT_SOURCE="$agent_source" \
    CALOPOD_SERVICE_TEST_HOST_SOURCE="$host_source" \
    "$repository_root/Scripts/calopod-service.sh" "$@"
}

run_service install \
  --interval-seconds 600 \
  --jitter-seconds 30 \
  --lookback-days 1 \
  --horizon-days 30 >/dev/null

service_root="$state_root/Service"
plist_path="$test_home/Library/LaunchAgents/com.calopod.agent.plist"
installed_agent="$service_root/bin/calopod-agent"
installed_host="$service_root/eventkit-host/Calopod EventKit Host.app/Contents/MacOS/CalopodEventKitHost"

[ -x "$installed_agent" ]
[ -x "$installed_host" ]
plutil -lint "$plist_path" >/dev/null
[ "$(plutil -extract Label raw "$plist_path")" = "com.calopod.agent" ]
[ "$(plutil -extract ProgramArguments.0 raw "$plist_path")" = "$installed_agent" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_STATE_PATH raw "$plist_path")" = "$state_root/state.sqlite" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_EVENTKIT_HOST_APP raw "$plist_path")" = "$service_root/eventkit-host/Calopod EventKit Host.app" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "600" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_JITTER_SECONDS raw "$plist_path")" = "30" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_LOOKBACK_DAYS raw "$plist_path")" = "1" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_HORIZON_DAYS raw "$plist_path")" = "30" ]
[ "$(plutil -extract RunAtLoad raw "$plist_path")" = "true" ]
[ "$(plutil -extract KeepAlive raw "$plist_path")" = "true" ]
[ "$(stat -f '%Lp' "$plist_path")" = "600" ]
[ "$(stat -f '%Lp' "$service_root/logs/agent.stdout.log")" = "600" ]
[ "$(stat -f '%Lp' "$service_root/logs/agent.stderr.log")" = "600" ]

printf '#!/bin/sh\nexit 2\n' > "$agent_source"
chmod 700 "$agent_source"
run_service install \
  --interval-seconds 900 \
  --jitter-seconds 45 \
  --lookback-days 2 \
  --horizon-days 60 >/dev/null
[ "$(tail -n 1 "$installed_agent")" = "exit 2" ]
[ "$(plutil -extract EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS raw "$plist_path")" = "900" ]
[ "$(cat "$state_root/state.sqlite")" = "state-sentinel" ]

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
