#!/bin/sh

set -efu

umask 077
setup_mode=main-busy
case "$#:${1:-}" in
  0:) ;;
  1:--arms) setup_mode=arms ;;
  1:--help|1:-h) echo "Usage: calopod-setup [--arms]"; exit 0 ;;
  *) echo "Usage: calopod-setup [--arms]" >&2; exit 64 ;;
esac
script_root=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
test_mode=${CALOPOD_SETUP_TEST_MODE:-0}

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

if [ "$test_mode" = "1" ]; then
  cli=${CALOPOD_SETUP_TEST_CLI:-}
  state_path=${CALOPOD_SETUP_TEST_STATE_PATH:-}
  case "$cli" in /*) ;; *) fail "The test CLI path must be absolute." 78 ;; esac
  case "$state_path" in /*) ;; *) fail "The test state path must be absolute." 78 ;; esac
else
  [ "$(/usr/bin/id -u)" -ne 0 ] || fail "Run setup as the signed-in user, not root." 77
  case "${HOME:-}" in /*) ;; *) fail "The user home directory is unavailable." 78 ;; esac
  [ -z "${CALOPOD_STATE_PATH:-}" ] \
    || fail "Unset CALOPOD_STATE_PATH so setup and the installed service use the same state." 78
  [ -z "${CALOPOD_EVENTKIT_HOST_APP:-}" ] \
    || fail "Unset CALOPOD_EVENTKIT_HOST_APP so setup uses the installed Calendar host." 78
  cli="$script_root/../bin/calopod"
  state_path="$HOME/Library/Application Support/Calopod/state.sqlite"
fi

[ -x "$cli" ] || fail "The installed Calopod CLI is unavailable. Reinstall Calopod." 66
[ -x /usr/bin/plutil ] || fail "The macOS property list utility is unavailable." 69

temporary_parent=${TMPDIR:-/tmp}
case "$temporary_parent" in /*) ;; *) fail "The temporary directory must be absolute." 78 ;; esac
temporary_parent=$(CDPATH= cd -- "$temporary_parent" && pwd -P)
temporary_root=$(/usr/bin/mktemp -d "$temporary_parent/calopod-setup.XXXXXX") \
  || fail "Could not create private setup storage." 74
case "$temporary_root" in
  "$temporary_parent"/calopod-setup.*) ;;
  *) fail "The private setup path is invalid." 74 ;;
esac
cleanup() {
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

extract() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

run_json() {
  output_file=$1
  shift
  "$cli" "$@" --format json > "$output_file"
}

prompt_yes() {
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r answer || return 1
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

prompt_number() {
  prompt=$1
  default=$2
  minimum=$3
  while :; do
    printf '%s [%s] ' "$prompt" "$default" >&2
    IFS= read -r value || fail "Setup was interrupted." 75
    [ -n "$value" ] || value=$default
    case "$value" in
      *[!0-9]*|'') echo "Enter a whole number." >&2 ;;
      *)
        [ "$value" -ge "$minimum" ] 2>/dev/null \
          || { echo "Enter a value of at least $minimum." >&2; continue; }
        printf '%s\n' "$value"
        return
        ;;
    esac
  done
}

display_value() {
  printf '%s' "$1" | LC_ALL=C /usr/bin/tr -cd '\40-\176'
}

calendar_line() {
  file=$1
  index=$2
  label=$(extract "$file" "data.items.$index.label" || printf 'Unnamed calendar')
  source_label=$(extract "$file" "data.items.$index.sourceLabel" || printf 'Local account')
  selected=$(extract "$file" "data.items.$index.selected" || printf 'false')
  read_only=$(extract "$file" "data.items.$index.readOnly" || printf 'false')
  suffix=""
  [ "$selected" != "true" ] || suffix="$suffix, selected"
  [ "$read_only" != "true" ] || suffix="$suffix, read only"
  printf '%s) ' "$((index + 1))"
  display_value "$label"
  printf ' ('
  display_value "$source_label"
  printf '%s)\n' "$suffix"
}

calendar_id_for_choice() {
  file=$1
  choice=$2
  count=$(extract "$file" data.count)
  case "$choice" in *[!0-9]*|'') return 1 ;; esac
  [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null \
    || return 1
  extract "$file" "data.items.$((choice - 1)).id"
}

calendar_is_available() {
  file=$1
  expected_id=$2
  count=$(extract "$file" data.count)
  index=0
  while [ "$index" -lt "$count" ]; do
    [ "$(extract "$file" "data.items.$index.id")" != "$expected_id" ] || return 0
    index=$((index + 1))
  done
  return 1
}

choose_sources() {
  file=$1
  count=$(extract "$file" data.count)
  [ "$count" -gt 0 ] || fail "No calendars are available." 78
  echo "Choose one or more source calendars. Labels are shown only in this terminal." >&2
  index=0
  while [ "$index" -lt "$count" ]; do
    calendar_line "$file" "$index" >&2
    index=$((index + 1))
  done
  while :; do
    printf 'Source numbers, separated by commas: ' >&2
    IFS= read -r choices || fail "Setup was interrupted." 75
    old_ifs=$IFS
    IFS=,
    set -- $choices
    IFS=$old_ifs
    selected_ids=""
    valid=true
    for choice do
      choice=$(printf '%s' "$choice" | /usr/bin/tr -d ' ')
      id=$(calendar_id_for_choice "$file" "$choice" || true)
      if [ -z "$id" ]; then
        valid=false
        break
      fi
      case " $selected_ids " in
        *" $id "*) ;;
        *) selected_ids="$selected_ids $id" ;;
      esac
    done
    [ "$valid" = "true" ] && [ -n "$selected_ids" ] && {
      printf '%s\n' "$selected_ids"
      return
    }
    echo "Choose at least one listed calendar." >&2
  done
}

choose_target() {
  file=$1
  purpose=$2
  excluded_id=${3:-}
  count=$(extract "$file" data.count)
  echo "Choose a writable, unselected calendar for $purpose." >&2
  index=0
  candidates=""
  while [ "$index" -lt "$count" ]; do
    id=$(extract "$file" "data.items.$index.id")
    selected=$(extract "$file" "data.items.$index.selected" || printf 'false')
    read_only=$(extract "$file" "data.items.$index.readOnly" || printf 'false')
    if [ "$selected" != "true" ] && [ "$read_only" != "true" ] \
      && [ "$id" != "$excluded_id" ]; then
      calendar_line "$file" "$index" >&2
      candidates="$candidates $((index + 1))"
    fi
    index=$((index + 1))
  done
  [ -n "$candidates" ] || fail "No safe target calendar is available for $purpose." 78
  while :; do
    printf '%s target number: ' "$purpose" >&2
    IFS= read -r choice || fail "Setup was interrupted." 75
    choice=$(printf '%s' "$choice" | /usr/bin/tr -d ' ')
    case " $candidates " in
      *" $choice "*)
        id=$(calendar_id_for_choice "$file" "$choice")
        prompt_yes "Confirm this is a fresh empty target used only by Calopod?" \
          || { echo "Choose a fresh empty target." >&2; continue; }
        printf '%s\n' "$id"
        return
        ;;
      *) echo "Choose one of the writable unselected calendars shown above." >&2 ;;
    esac
  done
}

choose_arm_target() {
  file=$1
  sources=$2
  count=$(extract "$file" data.count)
  echo "Choose a writable destination. It may also be a source for another Arm." >&2
  index=0
  candidates=""
  while [ "$index" -lt "$count" ]; do
    id=$(extract "$file" "data.items.$index.id")
    read_only=$(extract "$file" "data.items.$index.readOnly" || printf 'true')
    case " $sources " in
      *" $id "*) ;;
      *)
        if [ "$read_only" = "false" ]; then
          calendar_line "$file" "$index" >&2
          candidates="$candidates $((index + 1))"
        fi
        ;;
    esac
    index=$((index + 1))
  done
  [ -n "$candidates" ] || fail "No writable destination outside this Arm's sources is available." 78
  while :; do
    printf 'Destination number: ' >&2
    IFS= read -r choice || fail "Setup was interrupted." 75
    choice=$(printf '%s' "$choice" | /usr/bin/tr -d ' ')
    case " $candidates " in
      *" $choice "*)
        prompt_yes "Confirm this destination may receive managed copies and has no copies from an old Calopod setup?" \
          || { echo "Choose a destination without old Calopod copies." >&2; continue; }
        calendar_id_for_choice "$file" "$choice"
        return
        ;;
      *) echo "Choose one of the writable destinations shown above." >&2 ;;
    esac
  done
}

choose_arm_rule() {
  while :; do
    printf 'Rule: busy or full-details [busy]: ' >&2
    IFS= read -r rule || fail "Setup was interrupted." 75
    case "$rule" in
      ''|busy) printf '%s\n' busy; return ;;
      full-details)
        prompt_yes "Confirm this destination may receive source titles, locations, and notes?" || continue
        printf '%s\n' full-details; return
        ;;
      *) echo "Enter busy or full-details." >&2 ;;
    esac
  done
}

configure_custom_arms() {
  run_json "$arms_file" arm list
  configured=$(extract "$arms_file" data.count)
  if [ "$configured" -gt 0 ]; then
    echo "Preserving $configured existing Arm(s). Duplicate routes cannot be added."
    prompt_yes "Add another Arm?" || return 0
  fi
  while :; do
    custom_sources=$(choose_sources "$calendars_file")
    custom_target=$(choose_arm_target "$calendars_file" "$custom_sources")
    custom_rule=$(choose_arm_rule)
    printf 'Arm name (optional): ' >&2
    IFS= read -r custom_name || fail "Setup was interrupted." 75
    for source_id in $custom_sources; do
      run_json "$temporary_root/selection.json" calendars --connection eventkit-device --select "$source_id"
    done
    set -- arm add
    for source_id in $custom_sources; do
      set -- "$@" --source "$source_id"
    done
    set -- "$@" --target "$custom_target" --rule "$custom_rule"
    if [ -n "$custom_name" ]; then
      set -- "$@" --name "$custom_name"
    fi
    run_json "$arms_file" "$@"
    echo "Arm configured with the $custom_rule Rule."
    run_json "$calendars_file" calendars --connection eventkit-device
    prompt_yes "Add another Arm?" || break
  done
}

echo "Calopod guided setup"
if [ "$setup_mode" = "arms" ]; then
  echo "This configures custom Arms using Calendars on this Mac."
  echo "Original events stay unchanged. Managed copies are never copied onward."
else
  echo "This configures Calendars on this Mac, Main, Busy, and automatic sync."
fi

status_file="$temporary_root/status.json"
run_json "$status_file" agent status \
  || fail "Install the Calopod user service before running setup." 69
[ "$(extract "$status_file" data.installed || printf 'false')" = "true" ] \
  || fail "Install the Calopod user service before running setup." 69
was_enabled=$(extract "$status_file" data.enabled || printf 'false')
if [ "$was_enabled" = "true" ]; then
  disabled_file="$temporary_root/disabled.json"
  run_json "$disabled_file" agent disable
  echo "Automatic sync was stopped while setup changes configuration."
fi

if [ ! -f "$state_path" ]; then
  prompt_yes "No existing Calopod state was found. Create new private state?" \
    || fail "Setup stopped without creating state." 75
  echo "New state cannot own copies from an old Calopod setup. Do not reuse old managed copies."
else
  echo "Using the existing Calopod state."
fi

connection_file="$temporary_root/connection.json"
echo "Requesting Calendar access and refreshing the Mac Connection..."
run_json "$connection_file" connection add mac \
  || fail "Calendar access or Mac Connection refresh failed. Run calopod doctor." 77

calendars_file="$temporary_root/calendars.json"
run_json "$calendars_file" calendars --connection eventkit-device

main_file="$temporary_root/main.json"
arms_file="$temporary_root/arms.json"
if [ "$setup_mode" = "arms" ]; then
  configure_custom_arms
else
run_json "$main_file" main inspect
run_json "$arms_file" arm list
main_count=$(extract "$main_file" data.count)
arm_count=$(extract "$arms_file" data.count)
busy_present=false
busy_index=0
busy_target=""
while [ "$busy_index" -lt "$arm_count" ]; do
  kind=$(extract "$arms_file" "data.items.$busy_index.kind" || printf '')
  rule=$(extract "$arms_file" "data.items.$busy_index.rule" || printf '')
  enabled=$(extract "$arms_file" "data.items.$busy_index.enabled" || printf 'false')
  if [ "$kind" = "arm" ] && [ "$rule" = "busy" ] && [ "$enabled" = "true" ]; then
    busy_present=true
    busy_target=$(extract "$arms_file" "data.items.$busy_index.targetID")
    break
  fi
  busy_index=$((busy_index + 1))
done

source_ids=""
main_target=""
if [ "$main_count" -gt 0 ]; then
  source_index=0
  while id=$(extract "$main_file" "data.items.0.sourceIDs.$source_index" 2>/dev/null); do
    source_ids="$source_ids $id"
    source_index=$((source_index + 1))
  done
  main_target=$(extract "$main_file" data.items.0.targetID)
  echo "Existing Main configuration found; preserving it."
elif [ "$busy_present" = "true" ]; then
  source_index=0
  while id=$(extract "$arms_file" "data.items.$busy_index.sourceIDs.$source_index" 2>/dev/null); do
    source_ids="$source_ids $id"
    source_index=$((source_index + 1))
  done
  echo "Existing Busy configuration found; preserving its sources."
else
  source_ids=$(choose_sources "$calendars_file")
fi
[ -n "$source_ids" ] || fail "No source calendars are configured." 78
for source_id in $source_ids; do
  calendar_is_available "$calendars_file" "$source_id" \
    || fail "An existing source calendar is unavailable. Restore it in Calendar or repair the Arm configuration before setup." 78
done
if [ -n "$main_target" ]; then
  calendar_is_available "$calendars_file" "$main_target" \
    || fail "The existing Main target is unavailable. Restore it in Calendar or repair the Main configuration before setup." 78
fi
if [ -n "$busy_target" ]; then
  calendar_is_available "$calendars_file" "$busy_target" \
    || fail "An existing Busy target is unavailable. Restore it in Calendar or repair the Arm configuration before setup." 78
fi

for source_id in $source_ids; do
  selection_file="$temporary_root/selection.json"
  run_json "$selection_file" calendars --connection eventkit-device --select "$source_id"
done
run_json "$calendars_file" calendars --connection eventkit-device

if [ "$main_count" -eq 0 ]; then
  main_target=$(choose_target "$calendars_file" Main "$busy_target")
  set -- main configure
  for source_id in $source_ids; do
    set -- "$@" --source "$source_id"
  done
  set -- "$@" --target "$main_target"
  run_json "$main_file" "$@"
  echo "Main calendar configured."
fi

if [ "$busy_present" = "true" ]; then
  echo "Existing Busy configuration found; preserving it."
else
  busy_target=$(choose_target "$calendars_file" Busy "$main_target")
  set -- arm add
  for source_id in $source_ids; do
    set -- "$@" --source "$source_id"
  done
  set -- "$@" --target "$busy_target" --rule busy
  run_json "$arms_file" "$@"
  echo "Busy calendar configured."
fi

fi

current_interval=$(extract "$status_file" data.intervalSeconds)
current_jitter=$(extract "$status_file" data.jitterSeconds)
current_lookback=$(extract "$status_file" data.lookbackDays)
current_horizon=$(extract "$status_file" data.horizonDays)
interval=$(prompt_number "Automatic-sync interval in seconds" "$current_interval" 1)
jitter=$(prompt_number "Maximum jitter in seconds" "$current_jitter" 0)
lookback=$(prompt_number "Lookback in days" "$current_lookback" 0)
horizon=$(prompt_number "Horizon in days" "$current_horizon" 1)
schedule_file="$temporary_root/schedule.json"
run_json "$schedule_file" agent interval \
  --seconds "$interval" \
  --jitter-seconds "$jitter" \
  --lookback-days "$lookback" \
  --horizon-days "$horizon"

preview_file="$temporary_root/preview.json"
preview_day=$(/bin/date +%F)
echo "Calculating a bounded dry run for today..."
run_json "$preview_file" sync --dry-run --day "$preview_day"
preview_count=$(extract "$preview_file" data.count)
creates=0
updates=0
removals=0
repairs=0
no_ops=0
index=0
while [ "$index" -lt "$preview_count" ]; do
  operation=$(extract "$preview_file" "data.items.$index.kind")
  case "$operation" in
    create) creates=$((creates + 1)) ;;
    update) updates=$((updates + 1)) ;;
    remove) removals=$((removals + 1)) ;;
    repair) repairs=$((repairs + 1)) ;;
    no-op) no_ops=$((no_ops + 1)) ;;
  esac
  index=$((index + 1))
done
warning_count=0
while extract "$preview_file" "warnings.$warning_count" >/dev/null 2>&1; do
  warning_count=$((warning_count + 1))
done
printf 'Dry run: %s create, %s update, %s removal, %s repair, %s no-op, %s warning.\n' \
  "$creates" "$updates" "$removals" "$repairs" "$no_ops" "$warning_count"

if [ "$setup_mode" = "arms" ]; then
  echo "Automatic sync remains disabled. Apply and verify a manual sync before enabling it."
else
if [ "$was_enabled" = "true" ]; then
  enable_prompt="Re-enable automatic sync now?"
else
  enable_prompt="Enable automatic sync now?"
fi
if prompt_yes "$enable_prompt"; then
  enable_file="$temporary_root/enable.json"
  run_json "$enable_file" agent enable
else
  echo "Automatic sync remains disabled."
fi

fi

doctor_file="$temporary_root/doctor.json"
if run_json "$doctor_file" doctor; then
  doctor_exit=0
else
  doctor_exit=$?
fi
doctor_status=$(extract "$doctor_file" data.status || printf 'failed')
doctor_warnings=$(extract "$doctor_file" data.warningCount || printf '0')
printf 'Health check: %s with %s warning(s).\n' "$doctor_status" "$doctor_warnings"
[ "$doctor_exit" -eq 0 ] \
  || echo "Run calopod doctor for generic recovery guidance."
echo "Setup complete. Review the dry run before applying calendar changes."
