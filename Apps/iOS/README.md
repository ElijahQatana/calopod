# Calopod for iPhone

A read-only companion. The Mac publishes snapshots to the private CloudKit database
`iCloud.pro.elijahquintana.calopod` and this app reads them. It has no actions, no sign-in of its own and no calendar access.

Open `Calopod.xcodeproj` in Xcode 16 or later. The project needs the `Calopod` package one folder up, which Xcode finds on its own.

## Meeting reminders

The app sets local notifications from the events your Mac shares, so they arrive with the app closed. After each refresh and each time the app comes forward it keeps the next 24 hours of reminders in step with the snapshot. The times and whether titles are shown come from the Mac (`calopod notifications`), and the same events qualify: timed, not declined, not cancelled, not a Calopod copy, and on a calendar chosen for the iPhone. A reminder offers Join when the event has a meeting link, and tapping it opens the event in Calendar.

Status asks for notification permission with a short explanation, and has one switch to turn reminders off on this phone, for when the Mac already reminds you. The switch is kept on the phone only. Reminders use the normal interruption level, like the Mac. The app doesn't use Time Sensitive notifications.

A reminder can only be set when the app has run since the Mac published, because the phone has no push wake-up yet. See [the feed](../../docs/iphone-feed.md#reminders-on-the-iphone).

## Running on a device or a signed simulator build

iCloud only works when the build is signed with a team that owns the container. To use yours, create `Apps/iOS/Local.xcconfig`
(it is not tracked, so keep it out of commits) with:

    DEVELOPMENT_TEAM = YOUR_TEAM_ID

Without a team the app still runs, and shows "Sign in to iCloud to see your calendar" instead of reading anything.

## Fixture data

Launch with `-fixture fresh`, `stale`, `noCalendars` (busy time but no calendar chosen), `sharingOff`, `nothingPublished` or `offline` to use synthetic data with no iCloud.

## Tests

    xcodebuild -project Apps/iOS/Calopod.xcodeproj -scheme Calopod -destination 'platform=iOS Simulator,name=iPhone 17' test

Or run `Scripts/check-ios.sh` from the repository root, which also fails on warnings in this app's sources.

## Releasing

See [RELEASING.md](RELEASING.md).
