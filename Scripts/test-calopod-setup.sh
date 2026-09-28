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
  env \
    CALOPOD_SETUP_TEST_MODE=1 \
    CALOPOD_SETUP_TEST_CLI="$fake_cli" \
    CALOPOD_SETUP_TEST_STATE_PATH="$state_path" \
    CALOPOD_SETUP_FIXTURE_ROOT="$fixture_root" \
    "$repository_root/Scripts/calopod-setup.sh" \
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

echo "Guided setup checks passed."
