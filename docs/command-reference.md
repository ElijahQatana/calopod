# Command reference

Run any command with `--help` for its options.

```text
calopod connection add | list | inspect | disable | remove
calopod calendars
calopod arm add | list | inspect | update | disable | remove
calopod main configure | inspect
calopod events [skip | unskip | skipped]
calopod join [event]
calopod availability [find]
calopod hours [set|focus]
calopod notifications [set]
calopod sync
calopod inbox [activity | refresh | inspect | acknowledge | snooze | unsnooze | review | config]
calopod agent enable | disable | pause | resume | interval | run-now | status
calopod iphone [on | off | status | calendars]
calopod update [check]
calopod doctor
calopod support export | backup | verify | restore
calopod config export | import
calopod-setup [--arms]
```

`iphone on` and `iphone off` choose whether the Mac app uploads the [iPhone feed](iphone-feed.md); `iphone status` shows the choice and how the last upload went. `on` needs the Mac app, and `off` deletes the uploaded copy. `iphone calendars` lists your calendars and, with `--on` and `--off` (a calendar's identifier or exact name, repeatable), chooses which ones send their events to the phone. None are chosen at first, and the event titles of chosen calendars are stored in your iCloud. `iphone status` says how many are chosen.

`config export` prints your settings as a file and `config import FILE` loads one after showing the changes. See [Move to a new Mac](troubleshooting.md#move-to-a-new-mac).

`update check` asks GitHub for the newest release and says whether it is newer than the one you are running. It only reads: nothing is downloaded or installed, and no calendar data is sent. It exits with 75 if GitHub can't be reached. The Mac app does the same from Settings.

`connection add` takes `mac`, `google` or `microsoft`. `events` and `availability` take `--cached` to read local data without refreshing.

`hours` shows your working hours, one line per weekday, and `hours set --days mon-fri --start 09:00 --end 17:00` changes them. `--days` takes day names or short forms, ranges such as `mon-thu`, or `weekdays`, `weekend` and `all`, separated by commas. `--off` makes those days days off. On a working day you can give just `--start` or just `--end`; a day that is off needs both. The default is Monday to Friday, 9:00 to 17:00, and the times are in your local time zone. The Mac app edits the same hours in Settings.

`notifications` shows the meeting reminder and Inbox digest settings, and `notifications set` changes them: `--first` and `--final` for the reminder times, `--hide-titles`, and `--digest`, `--no-digest` and `--digest-at 08:30` for the digest. The notifications themselves come from the Mac app.

`availability` counts free and busy time only inside working hours. Busy time before or after them, and all of it on a day off, is listed separately and not counted as busy. `--ignore-working-hours` counts the whole day. In the JSON, items with `availability` of `busy` now cover only time inside working hours; before this change they also included time outside them. New items have `availability` set to `before-hours`, `after-hours` or `day-off`, with the label "Before hours", "After hours" or "Day off". A new `totals` object has `freeSeconds`, `busySeconds` and `outsideSeconds`. `workingWindows` is unchanged: one start and end for each working window in the range, left out when working hours are ignored.

`hours focus 90m` sets how long a free stretch must be to count as focus time, from 15 minutes to 24 hours, two hours by default; `hours` shows it as `focusMinutes` in JSON. `availability` JSON gains `days`, one entry per local day with `date`, `longestFreeSeconds` and `short`, which is true for a working day with no free stretch of `focusSeconds`. `totals` and the other fields are unchanged.

`availability find --duration 45m --within 5d` lists the free windows at least that long, from now. In JSON, `items` holds only free windows with `startsAt` and `endsAt`, and `lengthSeconds` is the length asked for. `schemaVersion` is unchanged.

`events` lists the Teams, Zoom, Meet or Webex link of each event (`Join:` in text, `joinProvider` and `joinURL` in JSON). `join` opens one: give it an id from `events --ids`, or leave it out for the event the menu bar card shows as next: the meeting that is on now during its first 10 minutes, then the next one to start within 12 hours. It opens the meeting app when there is one, otherwise the link in the browser.

`events skip ID` stops copying an event (`--series` for every event in its series), `events unskip ID` undoes it, and `events skipped` lists them. See [Event tags](tags.md#dont-copy-from-calopod).

`events --view all|sources|destinations` shows the calendars that view offers and leaves out the ones hidden in it. Each view keeps its own hidden calendars, the same ones the Mac app's Calendar screen remembers. `calendars hide CALENDAR --view VIEW` and `calendars show CALENDAR --view VIEW` change them. Without `--view`, or with `--calendar`, `events` hides nothing.

`calendars` lists the calendars the Mac app's Calendars screen shows. Calendars you ignored are left out, as the app keeps them under a collapsed Ignored section, and the text output ends with a line saying how many were left out. `calendars --include-ignored` lists them too, marked `Ignored: yes`. `Count` counts what is listed. In JSON output the default list now omits ignored calendars as well and adds a top-level `ignoredCount`; with `--include-ignored` it lists everything with the `ignored` flag as before and has no `ignoredCount`. Scripts that need every calendar should pass `--include-ignored`. An ignored calendar can still be named by identifier or exact name in `calendars --select`, `name`, `color`, `hide`, `show` and `unignore`. `calendars ignore CALENDAR` and `calendars unignore CALENDAR` change the same Ignored list the app uses and print how many calendars the default list now shows. Ignoring only hides a calendar: one that is still selected keeps syncing, and the list warns about it.

## Dates

`events`, `availability`, `inbox` and `sync` accept:

```text
--day 2026-09-24
--from 2026-09-24 --through 2026-10-01
--from 2026-09-24T09:00:00-04:00 --through 2026-09-24T17:00:00-04:00
--timezone America/New_York
```

- `--day` can't be combined with `--from` or `--through`, and those two go together.
- A plain date uses `--timezone`, or your system's. A plain `--through` includes that whole day.
- A timestamp needs `Z` or an offset and is taken exactly.
- `events` and `availability` default to today. `sync` needs a day or range so every run is bounded.
- Days are counted on the calendar, so a daylight-saving day can have 23 or 25 hours.

## Output

Text by default. `--ids` prints full, unshortened IDs. `--format json` gives a stable shape:

```json
{ "command": "events", "data": {}, "schemaVersion": 1, "warnings": [] }
```

`schemaVersion` goes up only if a change would break existing scripts. A status of `partial` means some sources couldn't be read; the warnings say which kind of problem.

Errors go to standard error. Secrets and provider responses are never printed, and meeting links appear only where described above.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 64 | Invalid command, option or date range |
| 69 | Provider or feature unavailable |
| 70 | Unexpected internal error |
| 74 | Couldn't read or write local data |
| 75 | Temporary provider failure, safe to retry |
| 77 | Sign-in or permission failure |
| 78 | Invalid or unsafe configuration |

## Settings

| Variable | Purpose |
|---|---|
| `CALOPOD_STATE_PATH` | Absolute path to the database, for tests and throwaway runs. |
| `CALOPOD_GOOGLE_CLIENT_ID` | Your Google desktop client ID. |
| `CALOPOD_GOOGLE_CLIENT_SECRET` | The secret of that Google desktop client. |
| `CALOPOD_MICROSOFT_CLIENT_ID` | Your Microsoft public client ID. |
| `CALOPOD_MICROSOFT_TENANT` | Microsoft tenant. Defaults to `common`. |

By default data lives in `~/Library/Application Support/Calopod/state.sqlite`.
