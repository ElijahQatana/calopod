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
- Copies made by Calopod are left out, so nothing is counted twice. Time that an Arm pads onto its copies is added to the events it copies, so it counts as busy.
- Free and busy time count only inside your working hours, so 3 a.m. isn't free and a 7 p.m. meeting doesn't make the day look fuller. Meetings before or after working hours, and every meeting on a day off, are listed separately as outside working hours, so a late meeting doesn't disappear. A meeting that crosses the start or end of the day is split there. Add `--ignore-working-hours` to count the whole day.

To find a free slot of a given length, use `availability find`:

```sh
calopod availability find --duration 45m --within 5d
```

It lists the free windows that are at least that long, starting from now, using the same busy time, padding and working hours as `availability`. `--within` takes days or hours (`5d`, `36h`) and defaults to 7 days; `--day` or `--from` and `--through` pick a range instead. Add `--ignore-working-hours` to count the whole day. `--cached`, `--connection`, `--calendar` and `--timezone` work as above. The Availability page in the Mac app has a Find a time field that does the same for the week it shows.

Add `--copy` to also copy the windows as plain text for a message, such as `Tue Nov 3, 2:00 to 4:00 PM EST`, in the time zone of the range. The text is printed too; where there is no clipboard tool, nothing is copied. JSON output is unchanged.

`availability` also lists each day's longest free stretch, and flags a working day with no stretch as long as your focus time, two hours until you change it. Days off are never flagged.

```sh
calopod hours focus 90m
```

Working hours are set per weekday in your local time zone, with days off allowed. Until you set them they are Monday to Friday, 9:00 to 17:00.

```sh
calopod hours
calopod hours set --days mon-thu --start 08:30 --end 17:00
calopod hours set --days fri --start 08:30 --end 13:00
calopod hours set --days sat,sun --off
```

The Mac app reads and changes the same hours and focus time in Settings.

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

An Arm copies everything unless you turn on a filter. `--skip-declined`, `--skip-all-day`, `--skip-dontclone` and `--skip-free` leave out events you declined, all-day events, events with `#dontclone` in the title or notes, and events marked Free. They work with `arm add`, and `arm update` takes them and the matching `--no-skip-...` flags. When an event starts to match a filter, the copy Calopod made of it is removed on the next sync, and the preview lists that as a removal. [Event tags](tags.md) work on every Arm: `#justbusy` copies one event as plain Busy.

```sh
calopod arm update ARM_ID --skip-declined --no-skip-all-day
```

Working location and birthday entries are never copied, because they are not commitments. An Out of office event is copied as Busy like any other. The preview names the reason when one of these is left out.

The default Rule is `busy`: the copy has the start, end and the title "Busy", nothing else. Use `full-details` only for a calendar you trust. It copies the title, location and notes, with attendees and links written into the notes. It never invites anyone and clears alerts so you aren't notified twice.

Rule `label` sits between the two: the copy has the start and end and a fixed title you set on the Arm, such as "Personal" or "Client". Nothing from the original's title, notes, location or people goes into it. A Private event is copied as plain "Busy" without the label. Changing an Arm's Rule or label updates its copies on the next sync instead of making new ones.

```sh
calopod arm add --source WORK_ID --target PERSONAL_ID --rule label --label "Client"
calopod arm update ARM_ID --label "Personal"
```

An Arm can also pad its Busy and Label copies. `--pad-before` and `--pad-after` take minutes (0 to 480, default 0), so the copy starts early and ends late and blocks travel or prep time on the other calendar. The original is never changed, all-day events are left alone, and Full details copies are not padded. `--pad-in-person-only` pads only events that have a location and no meeting link. Changing the padding updates the Arm's copies on the next sync. Availability counts the padded time as busy.

```sh
calopod arm add --source WORK_ID --target PERSONAL_ID --pad-before 15 --pad-after 15
calopod arm update ARM_ID --pad-after 30 --pad-in-person-only
```

`calopod arm list` also shows how each Arm is doing: when it last synced, the category of its last error, and how many changes are waiting. An Arm that has not synced yet says so, and a disabled one is marked disabled. The numbers come from the last sync or preview, so reading them makes no calls to your calendars.

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
