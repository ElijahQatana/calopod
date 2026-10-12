# Troubleshooting and backups

Start with:

```sh
calopod doctor
```

It lists what's wrong in plain categories, without private details.

## Share a health summary

```sh
umask 077
calopod support export --format json > calopod-support.json
```

The file contains generic checks, schedule values and counts only. It leaves out calendar and account names, IDs, event content, paths and tokens. Look it over before you send it.

Never attach your database, backups, logs, or terminal output that shows real calendar names or events. If you need to show a bug, recreate it with made-up events.

## Back up and restore

```sh
calopod support backup --output "$PWD/calopod-state-backup.sqlite"
calopod support verify --backup "$PWD/calopod-state-backup.sqlite"
```

The backup is a private copy of Calopod's database on this Mac. It holds your settings and cached event data, so treat it as private. It doesn't include Keychain items, so it won't work on a different Mac.

To restore:

```sh
calopod support verify --backup "$PWD/calopod-state-backup.sqlite"
calopod agent disable
calopod support restore --backup "$PWD/calopod-state-backup.sqlite" --confirm
calopod doctor
calopod agent enable
```

Your backup file is kept, and if the restore fails your current data is left in place.

## Calendar permission problems

If `doctor` reports `calendar-permission`, give the Calopod app full Calendar access in System Settings, under Privacy & Security, then Calendars. Then run:

```sh
calopod connection add mac
calopod doctor
```

An app that was rebuilt or signed differently counts as a new app to macOS, so it asks again.

## Account problems

If a Google or Microsoft account reports a sign-in or consent problem, reconnect just that account with `calopod connection add google` or `microsoft`.

## The service

- **Won't start or keeps idling.** `calopod agent status` and `calopod doctor` show an invalid schedule as `configuration`. Fix it with `calopod agent interval`.
- **"busy".** Another sync holds the lock. Wait for it to finish.
- **After sleep.** You get one fresh run, not a backlog of missed ones.
- **Offline.** The run fails without changing anything, and the next one recovers.
- **Restart it.** `launchctl kickstart -k "gui/$(id -u)/pro.elijahquintana.calopod.agent"`

Before you reuse target calendars with a new database, know that the new setup doesn't recognize the old copies, so you can end up with duplicates. Use empty targets for a clean start, or restore the old database.
