# Calopod for iPhone

A read-only companion. The Mac publishes snapshots to the private CloudKit database
`iCloud.pro.elijahquintana.calopod` and this app reads them. It has no actions, no sign-in of its own and no calendar access.

Open `Calopod.xcodeproj` in Xcode 16 or later. The project needs the `Calopod` package one folder up, which Xcode finds on its own.

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
