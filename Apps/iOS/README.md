# Calopod for iPhone

A read-only companion. The Mac publishes snapshots to the private CloudKit database
`iCloud.pro.elijahquintana.calopod` and this app reads them. It has no actions, no sign-in of its own and no calendar access.

Open `Calopod.xcodeproj` in Xcode 16 or later. The project needs the `Calopod` package one folder up, which Xcode finds on its own.

## Screens

Four tabs: Home, Inbox, Calendar and Status. Home is the small overview: how the last sync went, what needs you (each tile opens the Inbox on that filter), the next events today and the calendars chosen on the Mac. Calendar has a Schedule and Availability switch; Availability shows the week with a status dot per day, the chosen day's free and busy totals, working hours, free windows and busy blocks, all as the Mac worked them out. Both sides share the chosen day. Home's "Availability today" shows today's totals and opens it. A feed from an older Mac has no working hours, so the phone shows busy time only and says the Mac needs an update.

Tapping the logo on a tab opens a menu with Settings, Calendars (show or hide each calendar on this phone), Help and About. Settings holds only what belongs to the phone: the reminders switch and notification permission, Appearance (System, Light or Dark) and the iCloud state. Lead times and hidden titles are shown but set on the Mac. Everything is read only.

## Meeting reminders

The app sets local notifications from the events your Mac shares, so they arrive with the app closed. After each refresh and each time the app comes forward it keeps the next 24 hours of reminders in step with the snapshot. The times and whether titles are shown come from the Mac (`calopod notifications`), and the same events qualify: timed, not declined, not cancelled, not a Calopod copy, and on a calendar chosen for the iPhone. A reminder offers Join when the event has a meeting link, and tapping it opens the event in Calendar.

Settings asks for notification permission with a short explanation, and has one switch to turn reminders off on this phone, for when the Mac already reminds you. The switch is kept on the phone only. Reminders use the normal interruption level, like the Mac. The app doesn't use Time Sensitive notifications.

A reminder can only be set when the app has run since the Mac published, because the phone has no push wake-up yet. See [the feed](../../docs/iphone-feed.md#reminders-on-the-iphone).

## Running on a device or a signed simulator build

iCloud only works when the build is signed with a team that owns the container. To use yours, create `Apps/iOS/Local.xcconfig`
(it is not tracked, so keep it out of commits) with:

    DEVELOPMENT_TEAM = YOUR_TEAM_ID

Builds run from Xcode (Debug) read the CloudKit Production environment, where the Mac publishes, so a development-signed phone sees the same feed as TestFlight. This comes from `CalopodDebug.entitlements`; Release uses `Calopod.entitlements`, and App Store builds are always Production.

Without a team the app still runs, and shows "Sign in to iCloud to see your calendar" instead of reading anything.

The app icon is `Support/EventKitHost/Calopod.icon`, the same file the Mac app uses. The project references it in place, so there is only one copy to edit.

## Fixture data

Launch with `-fixture fresh`, `stale`, `noCalendars` (busy time but no calendar chosen), `sharingOff`, `nothingPublished`, `offline`, `manyCalendars` (eight calendars, two of them destinations) or `manyOldMac` (the same from a Mac that does not say which are destinations) to use synthetic data with no iCloud. Add `-fixtureNotifications denied` or `notDetermined` to see the other notification states, and `-appearance dark` to start in dark.

## Tests

    xcodebuild -project Apps/iOS/Calopod.xcodeproj -scheme Calopod -destination 'platform=iOS Simulator,name=iPhone 17' test

Or run `Scripts/check-ios.sh` from the repository root, which also fails on warnings in this app's sources.

## Releasing

See [RELEASING.md](RELEASING.md).
