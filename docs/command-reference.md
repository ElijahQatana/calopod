# Command reference

Run any command with `--help` for its options.

```text
calopod connection add | list | inspect | disable | remove
calopod calendars
calopod arm add | list | inspect | update | disable | remove
calopod main configure | inspect
calopod events
calopod join [event]
calopod availability
calopod sync
calopod inbox [activity | refresh | inspect | acknowledge | review | config]
calopod agent enable | disable | pause | resume | interval | run-now | status
calopod doctor
calopod support export | backup | verify | restore
calopod-setup [--arms]
```

`connection add` takes `mac`, `google` or `microsoft`. `events` and `availability` take `--cached` to read local data without refreshing.

`events` lists the Teams, Zoom, Meet or Webex link of each event (`Join:` in text, `joinProvider` and `joinURL` in JSON). `join` opens one: give it an id from `events --ids`, or leave it out for the next event with a link that is on now or starts within 12 hours. It opens the meeting app when there is one, otherwise the link in the browser.

`events --view all|sources|destinations` shows the calendars that view offers and leaves out the ones hidden in it. Each view keeps its own hidden calendars, the same ones the Mac app's Calendar screen remembers. `calendars hide CALENDAR --view VIEW` and `calendars show CALENDAR --view VIEW` change them. Without `--view`, or with `--calendar`, `events` hides nothing.

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
| `CALOPOD_MICROSOFT_CLIENT_ID` | Your Microsoft public client ID. |
| `CALOPOD_MICROSOFT_TENANT` | Microsoft tenant. Defaults to `common`. |

By default data lives in `~/Library/Application Support/Calopod/state.sqlite`.
