# Using Calopod

If you ran `calopod-setup`, most of this is already done. These are the commands behind it.

## Connect your Mac's calendars

```sh
calopod connection add mac
calopod calendars --connection eventkit-device
```

Calopod reads any account already in the Calendar app: iCloud, Google, Microsoft, Exchange, CalDAV. No developer accounts are needed.

Calendars start out unselected. Pick the ones Calopod should read:

```sh
calopod calendars --connection eventkit-device --select CALENDAR_ID
calopod calendars --connection eventkit-device --deselect CALENDAR_ID
```

Deselecting only stops Calopod reading it. Nothing changes in the Calendar app.

If you also connect a Google or Microsoft account directly, Calopod warns when it looks like the same account is selected twice and blocks the ones it recognizes. It can't always tell, so check custom account names yourself.

## See your events and availability

```sh
calopod events --day 2026-09-25
calopod availability --from 2026-09-25 --through 2026-09-30
```

Both read every selected calendar. Add `--connection` or `--calendar` to narrow them down. Add `--cached` to skip the refresh and read what Calopod already has, which works even while a sync is running. The result is marked `partial`, because nothing was checked for freshness. If one calendar can't be reached, you still get results from the others with a `partial` status and a warning. Don't ignore that warning when you're planning around the answer.

Availability rules:

- Events marked free don't block time. Busy, tentative, unavailable and out-of-office events do.
- Overlapping or touching busy time merges into one block, and free time is whatever is left.
- Copies made by Calopod are left out, so nothing is counted twice.
- Free time counts only inside your working hours, so 3 a.m. isn't free. Busy time outside them is still listed, so a late meeting doesn't disappear. Add `--ignore-working-hours` to count the whole day.

Working hours are set per weekday in your local time zone, with days off allowed. Until you set them they are Monday to Friday, 9:00 to 17:00.

```sh
calopod hours
calopod hours set --days mon-thu --start 08:30 --end 17:00
calopod hours set --days fri --start 08:30 --end 13:00
calopod hours set --days sat,sun --off
```

The Mac app reads and changes the same hours in Settings.

Dates can be a single `--day`, or `--from` and `--through`. A plain date means the whole local day, in your time zone unless you pass `--timezone`. Full timestamps need an offset such as `-04:00`.

## Set up an Arm

An Arm sends events from one or more calendars to one target calendar.

```sh
calopod arm add --source WORK_ID --target PERSONAL_ID --name "Work hours"
calopod arm add --source A_ID --source B_ID --target C_ID --rule full-details
calopod arm list --ids
calopod arm disable ARM_ID
calopod arm remove ARM_ID
```

The default Rule is `busy`: the copy has the start, end and the title "Busy", nothing else. Use `full-details` only for a calendar you trust. It copies the title, location and notes, with attendees and links written into the notes. It never invites anyone and clears alerts so you aren't notified twice.

Creating or removing an Arm only changes Calopod's settings. It doesn't touch your calendars. Calopod refuses targets that are read-only and routes that point at themselves or repeat another route.

## Main calendar

Main is a single target that gets every selected event with full details.

```sh
calopod main configure --source A_ID --source B_ID --target MAIN_ID
calopod main inspect
```

## Sync

Always preview first:

```sh
calopod sync --dry-run --day 2026-09-25
```

The preview lists what would be created, updated, removed or repaired, and why. Nothing is written. When it looks right, run it for real:

```sh
calopod sync --day 2026-09-25
```

Calopod only changes events it created and can prove are its own. On the Mac's calendars that includes matching the event's ID to what Calopod recorded, so a copied or moved marker is reported for review and never adopted or deleted. If something looks wrong, such as a missing marker or a calendar it couldn't fully read, it stops and says so instead of guessing. Running it again is safe. It won't pile up duplicates.

If you edit a copy by hand, the next sync may put it back. Edit the original instead.

## Copying between existing calendars

A calendar can hold your own events and Calopod's copies. Copies are never passed along to another Arm, so events don't bounce around in circles.

Example with three calendars, A, B and C:

| From | To | Rule |
|---|---|---|
| A and C | B | Busy |
| B | A | Full details |
| C | A | Busy |
| A and B | C | Full details |

Run `calopod-setup` and choose Custom Arms (or `calopod-setup --arms`) to build this interactively. Then check it:

```sh
calopod sync --dry-run --from 2026-09-25 --through 2026-10-25
calopod sync --from 2026-09-25 --through 2026-10-25
calopod sync --dry-run --from 2026-09-25 --through 2026-10-25
```

The second preview should show nothing left to do. Check by eye that originals are untouched, Busy copies show no details, and nothing came back to where it started. Try a throwaway event too: move it, then delete it, and make sure only its own copies follow.

Recurring events are copied one occurrence at a time, so moving one occurrence doesn't touch the rest.

On a Mac, each target calendar has one preferred Mac that writes to it. This stops two Macs from creating the same copy. To change it:

```sh
calopod arm update ARM_ID --prefer-current-device
```

## Output

Output is plain text by default. Add `--ids` to show full IDs you can paste into other commands, or `--format json` for scripts. Reports like `doctor` never include calendar names or event details, so they're safe to share.
