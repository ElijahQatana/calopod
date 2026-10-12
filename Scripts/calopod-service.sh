#!/bin/sh

set -eu

label="pro.elijahquintana.calopod.agent"
script_root=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_root/.." && pwd -P)
test_mode=${CALOPOD_SERVICE_TEST_MODE:-0}

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

require_absolute_path() {
  case "$1" in
    /*) ;;
    *) fail "A required path is not absolute." 78 ;;
  esac
}

resolve_home() {
  if [ "$test_mode" = "1" ]; then
    test_home=${CALOPOD_SERVICE_TEST_HOME:-}
    require_absolute_path "$test_home"
    case "$test_home" in
      */calopod-service-test.*/home|*/calopod-release-test.*/home) ;;
      *) fail "The test home is outside the expected temporary directory." 78 ;;
    esac
    [ -d "$test_home" ] || fail "The test home does not exist." 78
    CDPATH= cd -- "$test_home" && pwd -P
    return
  fi

  [ "$(id -u)" -ne 0 ] || fail "Run this command as the signed-in user, not root." 77
  case "${HOME:-}" in
    /*) ;;
    *) fail "The user home directory is not an absolute path." 78 ;;
  esac
  [ -d "$HOME" ] || fail "The user home directory is unavailable." 78
  [ "$(stat -f '%u' "$HOME")" = "$(id -u)" ] \
    || fail "The user home directory is not owned by the current user." 77
  CDPATH= cd -- "$HOME" && pwd -P
}

home_root=$(resolve_home)
user_id=$(id -u)
launch_domain="gui/$user_id"
service_target="$launch_domain/$label"
support_root="$home_root/Library/Application Support/Calopod"
service_root="$support_root/Service"
installed_binary="$service_root/bin/calopod-agent"
installed_cli="$service_root/bin/calopod"
installed_host="$service_root/eventkit-host/Calopod EventKit Host.app"
installed_release="$service_root/release"
state_path="$support_root/state.sqlite"
log_root="$service_root/logs"
stdout_path="$log_root/agent.stdout.log"
stderr_path="$log_root/agent.stderr.log"
launch_agents_root="$home_root/Library/LaunchAgents"
plist_path="$launch_agents_root/$label.plist"

validate_managed_paths() {
  require_absolute_path "$service_root"
  require_absolute_path "$installed_binary"
  require_absolute_path "$installed_cli"
  require_absolute_path "$installed_host"
  require_absolute_path "$installed_release"
  require_absolute_path "$state_path"
  require_absolute_path "$stdout_path"
  require_absolute_path "$stderr_path"
  require_absolute_path "$plist_path"
  [ "$service_root" = "$support_root/Service" ] \
    || fail "The service directory did not resolve to the expected location." 78
  [ "$installed_release" = "$service_root/release" ] \
    || fail "The release directory did not resolve to the expected location." 78
  [ "$plist_path" = "$home_root/Library/LaunchAgents/$label.plist" ] \
    || fail "The LaunchAgent path did not resolve to the expected location." 78
}

validate_managed_paths

usage() {
  cat <<'EOF'
Usage:
  Scripts/calopod-service.sh build
  Scripts/calopod-service.sh install \
    --interval-seconds N --jitter-seconds N \
    --lookback-days N --horizon-days N
  Scripts/calopod-service.sh load
  Scripts/calopod-service.sh unload
  Scripts/calopod-service.sh remove
EOF
}

is_loaded() {
  if [ "$test_mode" = "1" ]; then
    return 1
  fi
  launchctl print "$service_target" >/dev/null 2>&1
}

require_nonnegative_integer() {
  name=$1
  value=$2
  case "$value" in
    ''|*[!0-9]*) fail "$name must be a nonnegative integer." 64 ;;
  esac
}

require_positive_integer() {
  name=$1
  value=$2
  require_nonnegative_integer "$name" "$value"
  [ "$value" -gt 0 ] || fail "$name must be greater than zero." 64
}

source_agent_binary() {
  if [ -n "${CALOPOD_SERVICE_AGENT_SOURCE:-}" ]; then
    printf '%s\n' "$CALOPOD_SERVICE_AGENT_SOURCE"
    return
  fi
  if [ "$test_mode" = "1" ]; then
    printf '%s\n' "${CALOPOD_SERVICE_TEST_AGENT_SOURCE:-}"
    return
  fi
  binary_root=$(swift build \
    --package-path "$repository_root" \
    --configuration release \
    --show-bin-path) || exit $?
  printf '%s\n' "$binary_root/calopod-agent"
}

source_cli_binary() {
  if [ -n "${CALOPOD_SERVICE_CLI_SOURCE:-}" ]; then
    printf '%s\n' "$CALOPOD_SERVICE_CLI_SOURCE"
    return
  fi
  if [ "$test_mode" = "1" ]; then
    printf '%s\n' "${CALOPOD_SERVICE_TEST_CLI_SOURCE:-}"
    return
  fi
  binary_root=$(swift build \
    --package-path "$repository_root" \
    --configuration release \
    --show-bin-path) || exit $?
  printf '%s\n' "$binary_root/calopod"
}

source_eventkit_host() {
  if [ -n "${CALOPOD_SERVICE_HOST_SOURCE:-}" ]; then
    printf '%s\n' "$CALOPOD_SERVICE_HOST_SOURCE"
    return
  fi
  if [ "$test_mode" = "1" ]; then
    printf '%s\n' "${CALOPOD_SERVICE_TEST_HOST_SOURCE:-}"
    return
  fi
  printf '%s\n' "$repository_root/.build/eventkit-host/Calopod EventKit Host.app"
}

source_release_root() {
  printf '%s\n' "${CALOPOD_SERVICE_RELEASE_SOURCE:-}"
}

build_service() {
  [ "$test_mode" != "1" ] || fail "Build is unavailable in test mode." 64
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
  echo "Built the CLI, agent, and EventKit host."
}

render_plist() {
  destination=$1
  interval_seconds=$2
  jitter_seconds=$3
  lookback_days=$4
  horizon_days=$5

  plutil -create xml1 "$destination"
  plutil -insert Label -string "$label" "$destination"
  plutil -insert AssociatedBundleIdentifiers -json '["pro.elijahquintana.calopod.eventkit-host"]' "$destination"
  plutil -insert ProgramArguments -json '[]' "$destination"
  plutil -insert ProgramArguments.0 -string "$installed_binary" "$destination"
  plutil -insert EnvironmentVariables -json '{}' "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_STATE_PATH -string "$state_path" "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_EVENTKIT_HOST_APP -string "$installed_host" "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_AGENT_INTERVAL_SECONDS -string "$interval_seconds" "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_AGENT_JITTER_SECONDS -string "$jitter_seconds" "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_AGENT_LOOKBACK_DAYS -string "$lookback_days" "$destination"
  plutil -insert EnvironmentVariables.CALOPOD_AGENT_HORIZON_DAYS -string "$horizon_days" "$destination"
  plutil -insert RunAtLoad -bool true "$destination"
  plutil -insert KeepAlive -bool true "$destination"
  plutil -insert ProcessType -string Background "$destination"
  plutil -insert ThrottleInterval -integer 30 "$destination"
  plutil -insert StandardOutPath -string "$stdout_path" "$destination"
  plutil -insert StandardErrorPath -string "$stderr_path" "$destination"
  plutil -lint "$destination" >/dev/null
}

inject_test_failure() {
  [ "$test_mode" = "1" ] || return 0
  [ "${CALOPOD_SERVICE_TEST_FAILURE_POINT:-}" != "$1" ] \
    || fail "Injected service installation failure." 74
}

install_service() {
  interval_seconds=""
  jitter_seconds=""
  lookback_days=""
  horizon_days=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval-seconds)
        [ "$#" -ge 2 ] || fail "--interval-seconds requires a value." 64
        interval_seconds=$2
        shift 2
        ;;
      --jitter-seconds)
        [ "$#" -ge 2 ] || fail "--jitter-seconds requires a value." 64
        jitter_seconds=$2
        shift 2
        ;;
      --lookback-days)
        [ "$#" -ge 2 ] || fail "--lookback-days requires a value." 64
        lookback_days=$2
        shift 2
        ;;
      --horizon-days)
        [ "$#" -ge 2 ] || fail "--horizon-days requires a value." 64
        horizon_days=$2
        shift 2
        ;;
      *) fail "Unknown install option: $1" 64 ;;
    esac
  done

  require_positive_integer "--interval-seconds" "$interval_seconds"
  require_nonnegative_integer "--jitter-seconds" "$jitter_seconds"
  require_nonnegative_integer "--lookback-days" "$lookback_days"
  require_positive_integer "--horizon-days" "$horizon_days"
  is_loaded && fail "Unload the service before installing or upgrading it." 75

  agent_source=$(source_agent_binary) || exit $?
  cli_source=$(source_cli_binary) || exit $?
  host_source=$(source_eventkit_host)
  release_source=$(source_release_root)
  require_absolute_path "$agent_source"
  require_absolute_path "$cli_source"
  require_absolute_path "$host_source"
  [ -x "$agent_source" ] || fail "Build the release agent before installing it." 66
  [ -x "$cli_source" ] || fail "Build the release CLI before installing it." 66
  [ -d "$host_source" ] || fail "Build the EventKit host before installing it." 66
  [ -x "$host_source/Contents/MacOS/CalopodEventKitHost" ] \
    || fail "The EventKit host executable is missing." 66
  if [ "$test_mode" = "1" ]; then
    # Test mode skips the signature check, so only allow hosts inside the test root.
    case "$host_source" in
      "$(dirname "$home_root")"/*) ;;
      *) fail "The test host is outside the expected temporary directory." 78 ;;
    esac
  else
    codesign --verify --deep --strict "$host_source" >/dev/null 2>&1 \
      || fail "The EventKit host signature is invalid." 65
  fi
  if [ -n "$release_source" ]; then
    require_absolute_path "$release_source"
    [ -f "$release_source/VERSION" ] || fail "The release version is missing." 66
    [ -f "$release_source/SHA256SUMS" ] || fail "The release checksums are missing." 66
    if [ -e "$release_source/SIGNING" ]; then
      [ -f "$release_source/SIGNING" ] && [ ! -L "$release_source/SIGNING" ] \
        || fail "The release signing metadata is invalid." 65
      [ "$(cat "$release_source/SIGNING")" = developer-id-notarized-v1 ] \
        || fail "The release signing metadata is unsupported." 65
    fi
    [ -x "$release_source/uninstall" ] || fail "The release uninstaller is missing." 66
    [ -x "$release_source/Scripts/calopod-service.sh" ] \
      || fail "The release service installer is missing." 66
    [ -x "$release_source/Scripts/calopod-setup.sh" ] \
      || fail "The guided setup command is missing." 66
  fi

  umask 077
  install -d -m 700 "$support_root" "$launch_agents_root"
  staging_root=$(mktemp -d "$support_root/.service-install.XXXXXX") \
    || fail "Could not create the installation staging directory." 74
  backup_root=""
  moved_service=0
  installed_plist=0
  plist_temporary=""
  install_committed=0
  cleanup_install() {
    [ ! -e "$staging_root" ] || rm -rf "$staging_root"
    [ -z "$plist_temporary" ] || [ ! -e "$plist_temporary" ] || rm -f "$plist_temporary"
    if [ "$install_committed" -eq 0 ]; then
      if [ "$moved_service" -eq 1 ]; then
        [ ! -e "$service_root" ] || rm -rf "$service_root"
      fi
      if [ -n "$backup_root" ] && [ -e "$backup_root/Service" ]; then
        mv "$backup_root/Service" "$service_root"
      fi
      if [ "$installed_plist" -eq 1 ]; then
        [ ! -e "$plist_path" ] || rm -f "$plist_path"
      fi
      if [ -n "$backup_root" ] && [ -e "$backup_root/$label.plist" ]; then
        mv "$backup_root/$label.plist" "$plist_path"
      fi
    fi
    if [ -n "$backup_root" ] && [ -d "$backup_root" ]; then
      rm -rf "$backup_root"
    fi
  }
  trap cleanup_install EXIT HUP INT TERM

  install -d -m 700 \
    "$staging_root/bin" \
    "$staging_root/eventkit-host" \
    "$staging_root/logs"
  install -m 700 "$cli_source" "$staging_root/bin/calopod"
  install -m 700 "$agent_source" "$staging_root/bin/calopod-agent"
  ditto "$host_source" "$staging_root/eventkit-host/Calopod EventKit Host.app"
  : > "$staging_root/logs/agent.stdout.log"
  : > "$staging_root/logs/agent.stderr.log"
  chmod 600 \
    "$staging_root/logs/agent.stdout.log" \
    "$staging_root/logs/agent.stderr.log"
  if [ -n "$release_source" ]; then
    install -d -m 700 "$staging_root/release"
    install -m 600 "$release_source/VERSION" "$staging_root/release/VERSION"
    install -m 600 "$release_source/SHA256SUMS" "$staging_root/release/SHA256SUMS"
    if [ -f "$release_source/SIGNING" ]; then
      install -m 600 "$release_source/SIGNING" "$staging_root/release/SIGNING"
    fi
    install -m 700 "$release_source/uninstall" "$staging_root/release/uninstall"
    install -m 700 \
      "$release_source/Scripts/calopod-service.sh" \
      "$staging_root/release/calopod-service.sh"
    install -m 700 \
      "$release_source/Scripts/calopod-setup.sh" \
      "$staging_root/release/calopod-setup.sh"
  fi

  plist_staging="$staging_root/$label.plist"
  render_plist \
    "$plist_staging" \
    "$interval_seconds" \
    "$jitter_seconds" \
    "$lookback_days" \
    "$horizon_days"
  chmod 600 "$plist_staging"
  inject_test_failure "after-staging"

  if [ -e "$service_root" ] || [ -e "$plist_path" ]; then
    backup_root=$(mktemp -d "$support_root/.service-backup.XXXXXX") \
      || fail "Could not create the installation backup directory." 74
  fi
  if [ -e "$service_root" ]; then
    mv "$service_root" "$backup_root/Service"
  fi
  if [ -e "$plist_path" ]; then
    mv "$plist_path" "$backup_root/$label.plist"
  fi
  inject_test_failure "after-backup"

  mv "$staging_root" "$service_root" || {
    if [ -n "$backup_root" ] && [ -e "$backup_root/Service" ]; then
      mv "$backup_root/Service" "$service_root"
    fi
    fail "Could not install the service files." 74
  }
  staging_root=""
  moved_service=1
  inject_test_failure "after-service"

  "$installed_host/Contents/MacOS/CalopodEventKitHost" --register-app > /dev/null 2>&1 \
    || fail "The Calopod background app association could not be registered." 70

  plist_temporary="$launch_agents_root/.$label.plist.installing"
  install -m 600 "$service_root/$label.plist" "$plist_temporary"
  mv "$plist_temporary" "$plist_path"
  plist_temporary=""
  installed_plist=1
  inject_test_failure "after-plist"
  rm -f "$service_root/$label.plist"

  install_committed=1
  trap - EXIT HUP INT TERM

  if [ -n "$backup_root" ]; then
    rm -rf "$backup_root"
    backup_root=""
  fi
  echo "Installed the Calopod user service. User data was preserved."
}

load_service() {
  [ "$test_mode" != "1" ] || fail "Load is unavailable in test mode." 64
  [ -x "$installed_binary" ] || fail "Install the service before loading it." 66
  [ -x "$installed_host/Contents/MacOS/CalopodEventKitHost" ] \
    || fail "The installed EventKit host is incomplete." 66
  [ -f "$plist_path" ] || fail "The installed LaunchAgent property list is missing." 66
  plutil -lint "$plist_path" >/dev/null \
    || fail "The installed LaunchAgent property list is invalid." 65
  if is_loaded; then
    echo "The Calopod user service is already loaded."
    return
  fi
  launchctl enable "$service_target"
  launchctl bootstrap "$launch_domain" "$plist_path"
  echo "Loaded the Calopod user service."
}

unload_service() {
  if [ "$test_mode" = "1" ]; then
    return
  fi
  if ! is_loaded; then
    echo "The Calopod user service is not loaded."
    return
  fi
  launchctl bootout "$service_target"
  echo "Unloaded the Calopod user service."
}

remove_service() {
  unload_service
  validate_managed_paths
  if [ "$test_mode" != "1" ]; then
    launchctl enable "$service_target" >/dev/null 2>&1 || true
  fi
  [ ! -e "$plist_path" ] || rm -f "$plist_path"
  [ ! -e "$service_root" ] || rm -rf "$service_root"
  echo "Removed the Calopod user service. SQLite state and Keychain items were preserved."
}

command=${1:-}
case "$command" in
  build)
    [ "$#" -eq 1 ] || fail "build does not accept options." 64
    build_service
    ;;
  install)
    shift
    install_service "$@"
    ;;
  load)
    [ "$#" -eq 1 ] || fail "load does not accept options." 64
    load_service
    ;;
  unload)
    [ "$#" -eq 1 ] || fail "unload does not accept options." 64
    unload_service
    ;;
  remove)
    [ "$#" -eq 1 ] || fail "remove does not accept options." 64
    remove_service
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
