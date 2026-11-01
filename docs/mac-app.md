# The Mac app

The Calopod app does what the command line does, in windows. Build it with `Scripts/build-calopod-mac-app.sh`; it lives in the menu bar and in the Dock while its window is open.

## Screens

- **Overview** fits the window without scrolling. It shows whether syncing is healthy, what needs you (waiting invitations, overlaps, changes), what is next today, today's free and busy time, and your calendars with totals. A taller window shows more: every calendar, more upcoming events, a bar of today's busy time and the week with a dot per day. In a small window the lists shorten and the week becomes today and the next two days, and then the lists drop away, and the page scrolls only when something like a sync preview needs more room. Preview sync lists what a sync would create, update or remove. Apply plans again first, and if the list changed since you looked, it shows the new list instead of writing anything.
- **Calendar** shows the week or a day from Calopod's local copy. A dot marks an event that changed after you answered, a red ring marks an overlap, and hatched blocks are the Busy copies Calopod made. Select an event to see its details. All, Sources and Destinations each remember which calendars are hidden and whether copies are shown. The Availability page beside Schedule shows the week as a row of days, each with a dot: green for mostly free, yellow for tight, red for overbooked, and an empty ring for a day off. Each day also shows its longest free stretch, in yellow when it is shorter than your focus time. Choose a day to see its free and busy totals, its longest free stretch, how many events overlap, and its free windows and busy blocks. It uses your working hours, so free and busy time are only counted inside them. Meetings before or after the working day, and any on a day off, are listed under Outside working hours with their total, each marked before hours, after hours or day off. Overview adds a short note such as "plus 1 hr 30 min outside hours" to today's line when there are any. The page and it shows the same out of date warnings as the schedule. Overview links to it. Type a length such as 45m or 2h in Find a time to list the free windows that long in the week. Copy puts every window it found on the clipboard as plain text, times only.
- **Inbox** lists what needs attention. The filters (All, Needs RSVP, Maybe, Changed, Conflicts) only choose which rows you see. Snooze, on a row or with `Z` in Review, hides an event until later today, tomorrow or a date you pick, and sends nothing; the Snoozed filter lists what is put away, and an event comes back sooner if it changes, gains an overlap or starts. Review goes through the list one event at a time with a confirm step before any reply, and keeps your place if you stop. Acknowledge marks one change as seen on this Mac and never sends a reply.
- **Calendars** adds accounts and chooses which calendars Calopod reads. Each calendar has a color from a palette of twelve, a name you can change, and an ignore switch. These live only on this Mac. They never rename, recolor or change a calendar at the provider, and ignoring a calendar does not stop it from syncing.
- **Arms** lists where events are copied from and to. New arm builds one. Its Rule can be Busy only, Label (a title you set, such as Personal) or Full details; the Rule menu on each arm changes it. The Padding choice in an arm's more menu makes Busy and Label copies start and end earlier or later. Each arm's Filters menu leaves out declined events, all-day events, or events tagged `#dontclone` (see [Event tags](tags.md)); a copy of an event that starts to match is removed on the next sync. A line under each arm says when it last synced, its last error and how many changes are waiting.
- **Background sync** registers Calopod's own service with macOS and sets how often it runs. Allow it in System Settings, General, Login Items when asked.
- **Settings** starts with Updates: the version you have, a Check for updates button, and a switch to check once a day, which is off until you turn it on. It also sets your working hours for each weekday and how long a free stretch counts as focus time (the command line's `calopod hours` changes the same), meeting reminders, a daily Inbox digest, light or dark, how see-through the window is, and the window style. Its iPhone row turns on the [iPhone feed](iphone-feed.md), a read-only copy of the Inbox and busy time in your private iCloud, plus the events of any calendars you switch on under it, available only in a copy of the app signed for iCloud. It can also invite someone with another Apple ID to read the feed. Its Settings file row saves your setup to a file and loads one on another Mac, showing the changes first (see [Move to a new Mac](troubleshooting.md#move-to-a-new-mac)). Its Command line row links `~/.local/bin/calopod` to the command inside the app. A meeting reminder for an event that overlaps another real event adds a line such as "Overlaps with Design review", using the same overlaps as the Inbox; copies Calopod made do not count, and with titles hidden it says "Overlaps with another event". The digest is one notification a day with counts of what is waiting in the Inbox, such as "3 need a reply, 1 conflict", never titles. It is off until you turn it on, comes at the time you pick or the start of your working day, is skipped when nothing is waiting, and opens the Inbox when you click it. It uses the same notification permission as the reminders, and `calopod notifications set` changes it.

## First run

The first time, Overview offers a three step setup: connect an account, choose calendars, then choose where events go. Nothing is copied until you approve the preview at the end, and setup only finishes once that first sync completes. Skipping keeps your place.

## Build a signed test copy

Without a signing identity the app is signed ad hoc, which macOS treats as a new app after every build. To test the Calendar prompt with the same kind of signature as a release, set `CALOPOD_SIGN_IDENTITY` to a Developer ID Application identity (its name or SHA-1 hash from `security find-identity -v -p codesigning`):

```sh
CALOPOD_SIGN_IDENTITY="<identity>" Scripts/build-calopod-mac-app.sh
```

Every item is signed with the hardened runtime and a timestamp, and the app, the agent, the command and the Calendar helper carry the Calendar entitlement. macOS charges the helper's request to the app, so the app needs the Calendar usage text and entitlement too. The script verifies the result and prints each item's flags, team and entitlements. A build like this is not notarized, so Gatekeeper still reports it as unnotarized.

To install it, quit Calopod, copy it over the old one and ask the helper for access by hand:

```sh
ditto .build/mac-app/Calopod.app /Applications/Calopod.app
open -W -n "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app" --args --request-permission
```

A first answer of `{"requestOutcome":"granted",...}` or `"denied"` means macOS asked. `"undecided"` with `"not-determined"` means it did not.

## The command and the app

There are three ways to install Calopod: the command line only, the app only, or the app with its command. See [Install](install.md#three-ways-to-install) for what each gives you.

Move to the app, in Background sync, switches off the source or release install and registers the app's own service. If `~/.local/bin/calopod` still points at the old install, it then asks whether to use the command inside the app as well, so updating the app updates `calopod`. Nothing changes until you confirm. If the link can't be changed, the old one stays. Replace, in the Command line row in Settings, does the same later for any link that points somewhere else.

`calopod-setup` and `calopod-uninstall` stay linked to the old install's scripts and keep working. Uninstalling the old install leaves a `calopod` link that points into an app alone.

To go back, choose Remove in the Command line row, then run `./install` from the release folder to link the old command again. Or run `./install --replace-app-command` and skip Remove.

## If something looks wrong

If Background sync says macOS has no record of the app, install it in the Applications folder from a signed build. If it says it is waiting for approval, allow Calopod in Login Items and choose Move to the app again. Your existing service keeps running until the app's service is approved.
