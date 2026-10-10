#!/bin/sh

set -eu

fixture_root=${CALOPOD_SETUP_FIXTURE_ROOT:?}
state_path=${CALOPOD_SETUP_TEST_STATE_PATH:?}
printf '%s\n' "$*" >> "$fixture_root/calls.log"

enabled=false
[ ! -f "$fixture_root/enabled" ] || enabled=true
selected=false
[ ! -f "$fixture_root/source-selected" ] || selected=true

if [ "${1:-}" = "agent" ] && [ "${2:-}" = "status" ]; then
  cat <<EOF
{"command":"agent.status","data":{"status":"disabled","installed":true,"enabled":$enabled,"paused":false,"runState":"stopped","stateReady":true,"intervalSeconds":600,"jitterSeconds":30,"lookbackDays":1,"horizonDays":30},"warnings":[]}
EOF
elif [ "${1:-}" = "agent" ] && [ "${2:-}" = "disable" ]; then
  /bin/rm -f "$fixture_root/enabled"
  printf '%s\n' '{"command":"agent.disable","data":{"status":"ok"},"warnings":[]}'
elif [ "${1:-}" = "connection" ] && [ "${2:-}" = "add" ]; then
  /usr/bin/install -d -m 700 "$(dirname "$state_path")"
  : > "$state_path"
  printf '%s\n' '{"command":"connection.add","data":{"status":"ok","count":1},"warnings":[]}'
elif [ "${1:-}" = "calendars" ]; then
  select_id=""
  previous=""
  for argument do
    if [ "$previous" = "--select" ]; then select_id=$argument; fi
    previous=$argument
  done
  if [ -f "$fixture_root/custom-mode" ]; then
    if [ -n "$select_id" ]; then
      case "$select_id" in a|b|c) ;; *) exit 78 ;; esac
      : > "$fixture_root/selected-$select_id"
      printf '%s\n' '{"data":{"status":"ok","count":1},"warnings":[]}'
    else
      a=false; b=false; c=false
      [ ! -f "$fixture_root/selected-a" ] || a=true
      [ ! -f "$fixture_root/selected-b" ] || b=true
      [ ! -f "$fixture_root/selected-c" ] || c=true
      cat <<EOF
{"data":{"status":"ok","count":3,"items":[{"id":"a","kind":"calendar","label":"Synthetic A","selected":$a,"readOnly":false},{"id":"b","kind":"calendar","label":"Synthetic B","selected":$b,"readOnly":false},{"id":"c","kind":"calendar","label":"Synthetic C","selected":$c,"readOnly":false}]},"warnings":[]}
EOF
    fi
  elif [ -n "$select_id" ]; then
    [ "$select_id" = "source-one" ] || exit 78
    : > "$fixture_root/source-selected"
    printf '%s\n' '{"command":"calendars","data":{"status":"ok","count":1,"items":[{"id":"source-one","kind":"calendar","selected":true}]},"warnings":[]}'
  else
    selected=false
    [ ! -f "$fixture_root/source-selected" ] || selected=true
    if [ -f "$fixture_root/source-unavailable" ]; then
      cat <<EOF
{"command":"calendars","data":{"status":"ok","count":3,"items":[{"id":"main-target","kind":"calendar","label":"Main Target","selected":false,"readOnly":false,"sourceLabel":"Example Account"},{"id":"busy-target","kind":"calendar","label":"Busy Target","selected":false,"readOnly":false,"sourceLabel":"Example Account"},{"id":"archive","kind":"calendar","label":"Archive","selected":false,"readOnly":true,"sourceLabel":"Example Account"}]},"warnings":[]}
EOF
    else
      cat <<EOF
{"command":"calendars","data":{"status":"ok","count":4,"items":[{"id":"source-one","kind":"calendar","label":"Engineering","selected":$selected,"readOnly":false,"sourceLabel":"Example Account"},{"id":"main-target","kind":"calendar","label":"Main Target","selected":false,"readOnly":false,"sourceLabel":"Example Account"},{"id":"busy-target","kind":"calendar","label":"Busy Target","selected":false,"readOnly":false,"sourceLabel":"Example Account"},{"id":"archive","kind":"calendar","label":"Archive","selected":false,"readOnly":true,"sourceLabel":"Example Account"}]},"warnings":[]}
EOF
    fi
  fi
elif [ "${1:-}" = "main" ] && [ "${2:-}" = "inspect" ]; then
  if [ -f "$fixture_root/main-configured" ]; then
    printf '%s\n' '{"command":"main.inspect","data":{"status":"ok","count":1,"items":[{"id":"main-arm","kind":"main-calendar","sourceIDs":["source-one"],"targetID":"main-target","rule":"full-details","enabled":true}]},"warnings":[]}'
  else
    printf '%s\n' '{"command":"main.inspect","data":{"status":"ok","count":0,"items":[]},"warnings":[]}'
  fi
elif [ "${1:-}" = "main" ] && [ "${2:-}" = "configure" ]; then
  : > "$fixture_root/main-configured"
  printf '%s\n' '{"command":"main.configure","data":{"status":"ok","count":1},"warnings":[]}'
elif [ "${1:-}" = "arm" ] && [ "${2:-}" = "list" ]; then
  if [ "$*" = "arm list --format human" ]; then
    [ ! -f "$fixture_root/summary-failed" ] || exit 74
    count=0
    [ ! -f "$fixture_root/custom-arm-count" ] || count=$(cat "$fixture_root/custom-arm-count")
    printf 'Configured Arms.\nCount: %s\n' "$count"
  elif [ -f "$fixture_root/custom-mode" ]; then
    count=0
    [ ! -f "$fixture_root/custom-arm-count" ] || count=$(cat "$fixture_root/custom-arm-count")
    printf '{"data":{"status":"ok","count":%s,"items":[]},"warnings":[]}\n' "$count"
  elif [ -f "$fixture_root/busy-configured" ]; then
    printf '%s\n' '{"command":"arm.list","data":{"status":"ok","count":2,"items":[{"id":"main-arm","kind":"main-calendar","sourceIDs":["source-one"],"targetID":"main-target","rule":"full-details","enabled":true},{"id":"busy-arm","kind":"arm","sourceIDs":["source-one"],"targetID":"busy-target","rule":"busy","enabled":true}]},"warnings":[]}'
  elif [ -f "$fixture_root/main-configured" ]; then
    printf '%s\n' '{"command":"arm.list","data":{"status":"ok","count":1,"items":[{"id":"main-arm","kind":"main-calendar","sourceIDs":["source-one"],"targetID":"main-target","rule":"full-details","enabled":true}]},"warnings":[]}'
  else
    printf '%s\n' '{"command":"arm.list","data":{"status":"ok","count":0,"items":[]},"warnings":[]}'
  fi
elif [ "${1:-}" = "arm" ] && [ "${2:-}" = "add" ]; then
  if [ -f "$fixture_root/custom-mode" ]; then
    count=0
    [ ! -f "$fixture_root/custom-arm-count" ] || count=$(cat "$fixture_root/custom-arm-count")
    printf '%s\n' "$((count + 1))" > "$fixture_root/custom-arm-count"
  else
  : > "$fixture_root/busy-configured"
  fi
  printf '%s\n' '{"command":"arm.add","data":{"status":"ok","count":1},"warnings":[]}'
elif [ "${1:-}" = "agent" ] && [ "${2:-}" = "interval" ]; then
  printf '%s\n' '{"command":"agent.interval","data":{"status":"ok"},"warnings":[]}'
elif [ "${1:-}" = "sync" ] && [ "${2:-}" = "--dry-run" ]; then
  printf '%s\n' '{"command":"sync","data":{"status":"ok","count":2,"items":[{"kind":"create"},{"kind":"no-op"}]},"warnings":[]}'
elif [ "${1:-}" = "agent" ] && [ "${2:-}" = "enable" ]; then
  : > "$fixture_root/enabled"
  printf '%s\n' '{"command":"agent.enable","data":{"status":"ok"},"warnings":[]}'
elif [ "${1:-}" = "doctor" ]; then
  printf '%s\n' '{"command":"doctor","data":{"status":"attention","warningCount":1},"warnings":["Complete a generic follow-up check."]}'
else
  echo "Unexpected synthetic command: $*" >&2
  exit 64
fi
