# iPhone feed

The iPhone feed is a read-only copy of your Inbox, your busy time for the next two weeks, your calendar names with their colors, the events of the calendars you choose, and the time of the last sync. The Mac app puts it in your private iCloud so the iPhone app can show it. It is off until you turn it on, and nothing on the iPhone can change a calendar.

What goes up: for each Inbox item, its time, title, location, notes, link, organizer, how many people have answered, and the events it overlaps. For busy time, only start and end times. Events marked private keep their time and lose their words. The feed is stored in your own iCloud account, not on a Calopod server, and nobody else can read it.

Events are different: for each calendar you choose, the next 14 days of events go up with their titles, times, locations, whether they are all day, your reply and the calendar they belong to. So the titles of events on chosen calendars are stored in your iCloud. Notes, attendees and links are not sent, and neither are cancelled events, copies Calopod made, or calendars you ignored. No calendar is chosen until you pick one.

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

## What is stored in iCloud

One record type, `Snapshot`, in one zone, `Snapshots`, of the private database in container `iCloud.pro.elijahquintana.calopod`. There is one record per Inbox item, one per day of busy time, one for the calendar list and one for the sync status. Each day that has events on a chosen calendar adds one more, holding that day's events from all chosen calendars. The record name is the item's own id, so an upload replaces the old record.

| Field | Type | Holds |
|---|---|---|
| `kind` | String | `inbox-item`, `availability-day`, `calendar-day`, `calendars` or `sync-status` |
| `schemaVersion` | Int(64) | The version of the payload, currently 1. A reader skips any `kind` it does not know |
| `publishedAt` | Date/Time | When the Mac built the record |
| `payload` | Bytes | The record as JSON, in the shapes defined by `CalopodSnapshot` |

## For maintainers: deploy the schema first

Production record types can't be removed, so check this list before deploying. In the CloudKit Dashboard, open the container, choose the Development environment, and create the record type `Snapshot` with exactly the four fields above (or let a Development build create it by publishing once). No indexes are needed: the app lists a zone's records by reading its changes, not by querying. Then use **Deploy Schema Changes** to push it to Production. A Developer ID build only ever talks to Production, so until this is deployed the upload fails.

Building the app with the feed needs the container's App ID and a Developer ID provisioning profile that carries iCloud. See [Releasing](releasing.md#iphone-feed-signing).
