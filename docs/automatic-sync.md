# Automatic sync

Once the service is installed, these commands control it. They only affect your own login session. If you run from a source checkout, use `swift run --quiet calopod` in place of `calopod`.

Try a manual `sync` first. Turning this on lets Calopod write to your target calendars.

## Start and stop

```sh
calopod agent enable     # start and keep running after login
calopod agent disable    # stop and stay off after login
```

## Pause

```sh
calopod agent pause
calopod agent resume
```

Pause skips scheduled runs but leaves everything installed. `calopod agent run-now` runs once even while paused. If another sync is already running, it says `busy` instead of overlapping.

## Change the schedule

```sh
calopod agent interval --seconds 900 --jitter-seconds 45 --lookback-days 1 --horizon-days 30
```

Anything you leave out keeps its current value.

## Check on it

```sh
calopod agent status
calopod doctor
```

`status` shows whether the service is installed, enabled, paused and when it last succeeded. `doctor` checks the installed files, local data, account connections and Calendar permission, and lists each Arm's last sync, last error and waiting changes. Both leave out calendar names, accounts, event content and file paths, so you can share them.

For a short summary to share, use `calopod support export`. See [Troubleshooting](troubleshooting.md).

## How a run works

Each run uses the same code as `calopod sync`. It takes a lock so two syncs never write at once, syncs a window around today, records a summary, then waits for the interval plus some random jitter. A failure, such as no network or expired permission, waits the same way, so it never spins.

Disabled Arms are skipped. An Arm whose account is disabled is skipped without touching its calendars.

If the schedule is invalid at startup, the service reports a configuration problem and idles instead of crashing in a loop. Fix it with `calopod agent interval`.

The service reads these settings, which the installer fills in:

- `CALOPOD_AGENT_INTERVAL_SECONDS`
- `CALOPOD_AGENT_JITTER_SECONDS`
- `CALOPOD_AGENT_LOOKBACK_DAYS`
- `CALOPOD_AGENT_HORIZON_DAYS`

Calendar calls give up after 90 seconds (5 minutes when waiting for you to answer the permission prompt). Before each call Calopod checks that the Calendar helper app is correctly signed.
