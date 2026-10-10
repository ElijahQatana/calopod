#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
fixture_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/calopod-setup-test.XXXXXX")
cleanup() {
  /bin/rm -rf "$fixture_root"
}
trap cleanup EXIT HUP INT TERM

fake_cli="$fixture_root/calopod"
state_path="$fixture_root/state/state.sqlite"
call_log="$fixture_root/calls.log"

/bin/cp "$repository_root/Scripts/Fixtures/calopod-setup-cli.sh" "$fake_cli"
/bin/chmod 700 "$fake_cli"

run_setup() {
  input_file=$1
  output_file=$2
  shift 2
  env \
    CALOPOD_SETUP_TEST_MODE=1 \
    CALOPOD_SETUP_TEST_CLI="$fake_cli" \
    CALOPOD_SETUP_TEST_STATE_PATH="$state_path" \
    CALOPOD_SETUP_FIXTURE_ROOT="$fixture_root" \
    "$repository_root/Scripts/calopod-setup.sh" "$@" \
    < "$input_file" > "$output_file" 2>&1
}

first_input="$fixture_root/first-input"
first_output="$fixture_root/first-output"
printf 'y\n1\n2\ny\n3\ny\n\n\n\n\ny\n' > "$first_input"
run_setup "$first_input" "$first_output"

[ -f "$state_path" ]
[ -f "$fixture_root/main-configured" ]
[ -f "$fixture_root/busy-configured" ]
[ -f "$fixture_root/enabled" ]
grep -q '^agent interval --seconds 600 --jitter-seconds 30 --lookback-days 1 --horizon-days 30 --format json$' "$call_log"
grep -q '^sync --dry-run --day ' "$call_log"
grep -q 'Dry run: 1 create, 0 update, 0 removal, 0 repair, 1 no-op, 0 warning.' "$first_output"
grep -q 'Health check: attention with 1 warning(s).' "$first_output"
grep -q 'Setup complete.' "$first_output"
! grep -q '^arm list --format human$' "$call_log"

second_input="$fixture_root/second-input"
second_output="$fixture_root/second-output"
printf '\n\n\n\ny\n' > "$second_input"
run_setup "$second_input" "$second_output"

[ "$(grep -c '^main configure ' "$call_log")" -eq 1 ]
[ "$(grep -c '^arm add ' "$call_log")" -eq 1 ]
grep -q 'Existing Main configuration found; preserving it.' "$second_output"
grep -q 'Existing Busy configuration found; preserving it.' "$second_output"
grep -q 'Automatic sync was stopped while setup changes configuration.' "$second_output"
[ -f "$fixture_root/enabled" ]

/bin/rm -f "$fixture_root/main-configured"
busy_only_input="$fixture_root/busy-only-input"
busy_only_output="$fixture_root/busy-only-output"
printf '2\ny\n\n\n\n\nn\n' > "$busy_only_input"
run_setup "$busy_only_input" "$busy_only_output"

[ -f "$fixture_root/main-configured" ]
[ "$(grep -c '^main configure ' "$call_log")" -eq 2 ]
grep -q 'Existing Busy configuration found; preserving its sources.' "$busy_only_output"
grep -q 'Main calendar configured.' "$busy_only_output"

: > "$fixture_root/source-unavailable"
third_output="$fixture_root/third-output"
if run_setup /dev/null "$third_output"; then
  echo "Setup accepted an unavailable configured source." >&2
  exit 1
fi
grep -q 'An existing source calendar is unavailable.' "$third_output"

# Custom setup uses three calendars as both sources and destinations.
/bin/rm -f "$fixture_root/source-unavailable" "$fixture_root/enabled" "$state_path"
: > "$fixture_root/custom-mode"
: > "$call_log"
custom_input="$fixture_root/custom-input"
custom_output="$fixture_root/custom-output"
printf 'y\n1,3\n2\ny\n\nWork route\ny\n2\n1\ny\nfull-details\ny\n\ny\n3\n1\ny\n\n\ny\n1,2\n3\ny\nfull-details\ny\n\nn\n\n\n\n\n' > "$custom_input"
run_setup "$custom_input" "$custom_output" --arms
[ "$(cat "$fixture_root/custom-arm-count")" -eq 4 ]
[ ! -f "$fixture_root/enabled" ]
grep -q '^arm add --source a --source c --target b --rule busy --name Work route --format json$' "$call_log"
grep -q '^arm add --source b --target a --rule full-details --format json$' "$call_log"
grep -q '^arm add --source c --target a --rule busy --format json$' "$call_log"
grep -q '^arm add --source a --source b --target c --rule full-details --format json$' "$call_log"
! grep -q '^main configure ' "$call_log"
! grep -q '^agent enable ' "$call_log"
! grep -q '^sync --from\|^sync --day' "$call_log"
grep -q 'Original events stay unchanged.' "$custom_output"
grep -q 'Apply and verify a manual sync before enabling it.' "$custom_output"

grep -q 'Arm routing summary (labels are shown only in this terminal):' "$custom_output"
grep -q '^Count: 4$' "$custom_output"
awk '
  /^arm add / { last_add = NR }
  /^arm list --format human$/ { summary = NR }
  /^sync --dry-run / { preview = NR }
  END { exit !(last_add < summary && summary < preview) }
' "$call_log"

# Rerunning custom setup preserves existing Arms without adding duplicates.
: > "$call_log"
printf 'n\n\n\n\n\n' > "$custom_input"
run_setup "$custom_input" "$custom_output" --arms
[ "$(cat "$fixture_root/custom-arm-count")" -eq 4 ]
grep -q 'Preserving 4 existing Arm(s).' "$custom_output"
grep -q '^Count: 4$' "$custom_output"
grep -q '^arm list --format human$' "$call_log"
! grep -q '^arm add ' "$call_log"
! grep -q '^agent enable ' "$call_log"

# A failed summary stops setup before the dry run.
: > "$fixture_root/summary-failed"
: > "$call_log"
printf 'n\n' > "$custom_input"
if run_setup "$custom_input" "$custom_output" --arms; then
  echo "Custom setup continued after a failed summary." >&2
  exit 1
fi
grep -q 'Could not read the configured Arms. Automatic sync remains disabled.' "$custom_output"
! grep -q '^sync ' "$call_log"
[ ! -f "$fixture_root/enabled" ]
/bin/rm -f "$fixture_root/summary-failed"

# Refuse a destination that is one of the same Arm's sources.
printf 'y\n1,2,3\n' > "$custom_input"
if run_setup "$custom_input" "$custom_output" --arms; then
  echo "Custom setup accepted a self-route." >&2
  exit 1
fi
grep -q "No writable destination outside this Arm's sources is available." "$custom_output"
[ "$(cat "$fixture_root/custom-arm-count")" -eq 4 ]

echo "Guided setup checks passed."
