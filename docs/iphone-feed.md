# iPhone feed

The iPhone feed is a read-only copy of your Inbox, your busy time for the next two weeks, your calendar names with their colors, the events of the calendars you choose, your meeting reminder settings, and the time of the last sync. The Mac app puts it in your private iCloud so the iPhone app can show it. It is off until you turn it on, and nothing on the iPhone can change a calendar.

What goes up: for each Inbox item, its time, title, location, notes, link, organizer, how many people have answered, and the events it overlaps. For busy time, only start and end times. Events marked private keep their time and lose their words. The feed is stored in your own iCloud account, not on a Calopod server. Nobody else can read it unless you [invite them](#sharing-with-another-apple-id).

Events are different: for each calendar you choose, the next 14 days of events go up with their titles, times, locations, whether they are all day, your reply and the calendar they belong to. So the titles of events on chosen calendars are stored in your iCloud. Notes and attendees are not sent, and neither are cancelled events, copies Calopod made, or calendars you ignored. No calendar is chosen until you pick one.

Meeting links are the one link that goes up. An event that can get a reminder (timed, not declined, not yet over, not private) carries its Teams, Zoom, Meet or Webex link so the phone can offer Join. Those links are stored in your iCloud with the event. The reminder settings are the ones from `calopod notifications`: whether reminders are on, the first and final times, and whether titles are hidden. A change reaches the phone at the next sync, like the choice of calendars.

## Calendar colors

Calendar colors come from one palette of twelve, defined in `CalopodDomain` and used by the Mac app, the command line and the iPhone app. Each calendar in the feed carries the id of its color (for example `indigo`) and also its position in the palette. The phone uses the id. It falls back to the position only for a feed from a Mac that sent no id, and shows the neutral gray for an id or position it doesn't know. A position outside the palette still makes the calendar list unreadable, as before. Both fields are part of the calendar list's payload, so there is no change to the iCloud schema.

## Reminders on the iPhone

The iPhone app schedules its own notifications from the feed. It keeps the next 24 hours of reminders pending, using the lead times and the hidden titles choice from the reminder settings record, for the same events the Mac reminds about. It does this every time it reads the feed and every time it comes forward. If the Mac has not published reminder settings (an older Mac), the phone sets none.

Because the phone and the Mac both remind you, the iPhone app has one switch in Settings, from the menu behind the logo, to turn its reminders off. It is not shared with the Mac. Reminders appear only after the app has read a feed that lists the event, so a meeting added on the Mac just before it starts may not get one on the phone.

## Turning it on

In the Mac app, open Settings and use **Show Inbox and busy time on iPhone**. From the command line:

```sh
calopod iphone on
calopod iphone off
calopod iphone status
```

To choose which calendars send events, switch them on under the iPhone row in Settings, or use the command line. Changing the choice uploads again at the next sync, and a calendar you switch off has its events removed from iCloud then.

```sh
calopod iphone calendars
calopod iphone calendars --on Work --off Holidays
```

Only the Mac app can upload, because only the signed app can use iCloud. The command line just flips the setting, which both share, and the app uploads the next time it runs. A source install with no app can't turn it on, and `calopod doctor` says `iPhone feed: not available (no app)`. A copy of the app built without a provisioning profile says it isn't signed for iCloud. Everything else works the same with the feed off.

The app uploads after each sync it sees finish, including syncs run by the background service. If an upload fails, the sync card and Settings say so and the app tries again in a few minutes. A failed upload never makes a sync fail.

Turning the feed off deletes the uploaded copy. If the app isn't running at that moment, it deletes the copy the next time it starts.

## Sharing with another Apple ID

An iPhone only reads the feed of the Apple ID it is signed in to. If your phone uses a different one, share the feed with it.

In Settings, under the iPhone row, choose **Invite someone**, enter their Apple ID email and pick what they can read:

- **Free and busy time only**: when you are busy for the next two weeks, when the Mac last synced, and the Mac's name. No titles, places, notes, links or calendar names.
- **Everything in the feed**: all of that plus Inbox items, chosen events and reminder settings.

The invite screen says this before anything is sent. Calopod then shows a link to send them. They open it on an iPhone with Calopod, signed in to the Apple ID you invited, and the feed appears with the Mac's name on it. They can only read it. The iPhone row lists who is invited or has accepted, with a Remove button for each, and **Stop sharing** ends a share for everyone. Turning the feed off deletes the copy and every share with it.

On the phone, Settings has a Feed section listing every feed it can read. The phone's own feeds come first, and a shared feed shows only when there is no feed of its own, unless you pick it. A feed someone stops sharing drops out of the list.

## What is stored in iCloud

One record type, `Snapshot`, in the private database of container `iCloud.pro.elijahquintana.calopod`. Each Mac writes only to its own zone, `Snapshots-` plus an id made once on that Mac. A Mac sharing busy time only also has a `-busy` zone with just the busy-time and sync-status records. Older versions wrote one shared zone named `Snapshots`. The first upload from an updated Mac deletes it, and the phone reads it until then. Each zone has one record per Inbox item, one per day of busy time, one for the calendar list, one for the reminder settings and one for the sync status. Each day that has events on a chosen calendar adds one more, holding that day's events from all chosen calendars. The record name is the item's own id, so an upload replaces the old record.

| Field | Type | Holds |
|---|---|---|
| `kind` | String | `inbox-item`, `availability-day`, `calendar-day`, `calendars`, `reminder-settings` or `sync-status` |
| `schemaVersion` | Int(64) | The version of the payload, currently 1. A reader skips any `kind` it does not know |
| `publishedAt` | Date/Time | When the Mac built the record |
| `payload` | Bytes | The record as JSON, in the shapes defined by `CalopodSnapshot` |

The `availability-day` payload holds each of the next 14 days, already worked out with the same calculation as the Mac app and `calopod availability`, so the phone does no arithmetic of its own. Besides `day`, `timeZoneIdentifier` and `busy` (the busy blocks inside working hours, cut at midnight; when `working` is missing, every busy block of the day), it can carry `working` (the working hours of that day as a start and end, left out on a day off), `free` (the gaps inside `working`), `overlaps` (how many events start before an earlier one has ended) and `status` (`mostlyFree`, `tight`, `overbooked` or `dayOff`, with the thresholds of the Mac's day dots) and `outside` (the busy blocks before or after working hours, and all of them on a day off, each with a `side` of `before`, `after` or `dayOff`, cut at midnight). Times are real dates rather than minutes after midnight, so a day with a clock change needs no special case. Free, busy and outside totals are the sums of `free`, `busy` and `outside`. An older phone that does not know `outside` still shows the right busy figure, because `busy` leaves out time outside working hours whenever `working` is sent. On a day off `busy` is empty and the meetings are in `outside`. A feed from an older Mac leaves the new fields out, and the phone then only has `busy`, which includes everything.

## For maintainers: deploy the schema first

Zones and shares need no schema: sharing uses CloudKit's own share records. Production record types can't be removed, so check this list before deploying. In the CloudKit Dashboard, open the container, choose the Development environment, and create the record type `Snapshot` with exactly the four fields above (or let a Development build create it by publishing once). No indexes are needed: the app lists a zone's records by reading its changes, not by querying. Then use **Deploy Schema Changes** to push it to Production. A Developer ID build only ever talks to Production, so until this is deployed the upload fails.

Building the app with the feed needs the container's App ID and a Developer ID provisioning profile that carries iCloud. See [Releasing](releasing.md#iphone-feed-signing).
