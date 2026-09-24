#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
probe_binary="$repository_root/.build/eventkit-probe/CalopodEventKitProbe.app/Contents/MacOS/CalopodEventKitProbe"
label="com.calopod.eventkit-access-probe"
service_target="gui/$(id -u)/$label"
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/calopod-eventkit-launch-agent.XXXXXX")
plist_path="$probe_root/$label.plist"
stdout_path="$probe_root/stdout.log"
stderr_path="$probe_root/stderr.log"

cleanup() {
  launchctl bootout "$service_target" >/dev/null 2>&1 || true
  rm -rf "$probe_root"
}
trap cleanup EXIT

if [ ! -x "$probe_binary" ]; then
  echo "Build the EventKit probe first." >&2
  exit 66
fi

plutil -create xml1 "$plist_path"
plutil -insert Label -string "$label" "$plist_path"
plutil -insert ProgramArguments -json "[]" "$plist_path"
plutil -insert ProgramArguments.0 -string "$probe_binary" "$plist_path"
plutil -insert ProgramArguments.1 -string "--check" "$plist_path"
plutil -insert RunAtLoad -bool true "$plist_path"
plutil -insert StandardOutPath -string "$stdout_path" "$plist_path"
plutil -insert StandardErrorPath -string "$stderr_path" "$plist_path"

launchctl bootstrap "gui/$(id -u)" "$plist_path"

attempt=0
while [ "$attempt" -lt 20 ]; do
  if launchctl print "$service_target" 2>/dev/null | grep -q "state = exited"; then
    break
  fi
  sleep 0.25
  attempt=$((attempt + 1))
done

if [ -s "$stdout_path" ]; then
  cat "$stdout_path"
fi

if [ -s "$stderr_path" ]; then
  cat "$stderr_path" >&2
fi

exit_status=$(launchctl print "$service_target" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = //p' | head -n 1)
exit "${exit_status:-1}"
