# The Mac app

The Calopod app does what the command line does, in windows. Build it with `Scripts/build-calopod-mac-app.sh`; it lives in the menu bar and in the Dock while its window is open.

## Screens

- **Overview** shows whether syncing is healthy, what needs you (waiting invitations, overlaps, changes) and what is next today. Preview sync lists what a sync would create, update or remove. Apply plans again first, and if the list changed since you looked, it shows the new list instead of writing anything.
- **Calendar** shows the week or a day from Calopod's local copy. A dot marks an event that changed after you answered, a red ring marks an overlap, and hatched blocks are the Busy copies Calopod made. Select an event to see its details.
- **Inbox** lists what needs attention. The filters (All, Needs RSVP, Maybe, Changed, Conflicts) only choose which rows you see. Review goes through the list one event at a time with a confirm step before any reply, and keeps your place if you stop. Acknowledge marks one change as seen on this Mac and never sends a reply.
- **Calendars** adds accounts and chooses which calendars Calopod reads. Each calendar has a color from a palette of twelve, a name you can change, and an ignore switch. These live only on this Mac. They never rename, recolor or change a calendar at the provider, and ignoring a calendar does not stop it from syncing.
- **Arms** lists where events are copied from and to. New arm builds one.
- **Background sync** registers Calopod's own service with macOS and sets how often it runs. Allow it in System Settings, General, Login Items when asked.
- **Settings** sets light or dark, how see-through the window is, and the window style.

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

## If something looks wrong

If Background sync says macOS has no record of the app, install it in the Applications folder from a signed build. If it says it is waiting for approval, allow Calopod in Login Items and choose Move to the app again. Your existing service keeps running until the app's service is approved.
