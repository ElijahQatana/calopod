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

The backup is a single-file copy of Calopod's database on this Mac. It holds your settings and the event details Calopod has cached (see [What Calopod stores](#what-calopod-stores)). It's encrypted with a key that Calopod keeps in your Keychain, and `verify` reports `Backup encrypted: yes`. That key doesn't leave this Mac, so a backup can't be opened on a different one, and if you lose the Keychain item you lose the backup. Backups made by earlier versions are plain files; they still verify and restore.

To restore:

```sh
calopod support verify --backup "$PWD/calopod-state-backup.sqlite"
calopod agent disable
calopod support restore --backup "$PWD/calopod-state-backup.sqlite" --confirm
calopod doctor
calopod agent enable
```

Restore waits for any running sync, refresh or cached read to finish and refuses while one is active. Your backup file is kept, and if the restore fails your current data is left in place. If a crash left `-wal` or `-shm` files next to the database, don't delete them; restore recovers them first.

## Move to a new Mac

A backup can't be opened on another Mac, but your setup can move in a settings file.

```sh
umask 077
calopod config export > calopod-config.json
```

Unlike `support export`, this file has your calendar and account names in it. Don't share it or attach it to an issue.

It holds your Connections (the kind and name), the calendars you selected, your Arms and Main calendar, calendar names, colors, ignored and hidden calendars, working hours, reminders, Inbox margins and digest, which calendars go to the iPhone feed, and the events you chose not to copy. The feed itself stays off until you turn it on. It leaves out sign-ins, the signing key, cached events, history and this Mac's ids. The file is versioned, and a Calopod that is older than the file refuses it.

On the new Mac, add your Connections first (`calopod connection add`, which means signing in again), then:

```sh
calopod config import calopod-config.json
```

Import lists what it would add or change and waits for a yes. `--dry-run` only lists, and `--yes` skips the question. It writes only to Calopod's own data on this Mac and never to a calendar or an invitation. A Connection it can't find is named, so you can add it and import again. A calendar that can't be matched by name and account is listed and left alone, and an Arm that needs one is not added. A skipped event travels by its series or server id. One that only the old Mac can identify, such as a single event in a Mac calendar with no server id, is listed and left alone. Nothing is guessed.

Copies the old Mac made carry a signature from a key that stays in the old Mac's Keychain, so the new Mac can't prove they are its own. It never adopts or deletes them. An Arm that finds one stops and reports it, and its other copies wait. Before the first sync on the new Mac, delete the Calopod copies from the target calendars, or do that on the old Mac before you export. Your original events are not touched. The Arm then makes fresh copies. Stop the old Mac's Arms, or stop using it, so it doesn't write copies to the same calendars again.

The Mac app has Export settings and Import settings under Settings, General.

## What Calopod stores

To keep the inbox, change detection, replies and full-details copies working, Calopod caches event details from your calendars, including events marked private: titles, notes, locations, links, organizer and attendee names and emails, times, and your response. It also keeps connection and calendar names and the inbox history.

All of this sits in a SQLite file that only your user can read. Calopod doesn't encrypt it or hide private events, so anything running as you can read it. FileVault protects the disk. Backups are encrypted; a copy of the live file is not. Sign-in tokens and the signing key are in the Keychain instead. History older than 90 days is cleaned up automatically.

## Calendar permission problems

If `doctor` reports `calendar-permission`, give the Calopod app full Calendar access in System Settings, under Privacy & Security, then Calendars. Then run:

```sh
calopod connection add mac
calopod doctor
```

An app that was rebuilt or signed differently counts as a new app to macOS, so it asks again.

## The Mac app's background service

If Background sync says macOS has no record of the app, the app is running from a build folder or is not signed with a developer identity. Install it in the Applications folder from a signed build. If it says it is waiting for approval, allow Calopod in System Settings, General, Login Items, then choose Move to the app again. A source-installed service keeps running until the app's service is approved.

## Account problems

If a Google or Microsoft account reports a sign-in or consent problem, reconnect just that account with `calopod connection add google` or `microsoft`.

## The service

- **Won't start or keeps idling.** `calopod agent status` and `calopod doctor` show an invalid schedule as `configuration`. Fix it with `calopod agent interval`.
- **"busy".** Another sync holds the lock. Wait for it to finish.
- **After sleep.** You get one fresh run, not a backlog of missed ones.
- **Offline.** The run fails without changing anything, and the next one recovers.
- **Restart it.** `launchctl kickstart -k "gui/$(id -u)/pro.elijahquintana.calopod.agent"`

Before you reuse target calendars with a new database, know that the new setup doesn't recognize the old copies, so you can end up with duplicates. Use empty targets for a clean start, or restore the old database.
