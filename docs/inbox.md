# Inbox and invitations

The inbox gathers events that need your attention from the calendars you selected:

- invitations you haven't answered (Needs RSVP)
- invitations you answered Maybe
- events that changed after you responded
- events that overlap another event (conflicts)

```sh
calopod inbox
calopod inbox --conflicts --exclude-maybe
calopod inbox --day 2026-11-05 --timezone America/New_York
calopod inbox activity
calopod inbox refresh --from 2026-11-05 --through 2026-11-12
```

`inbox`, `activity` and `inspect` read Calopod's local copy and are instant, even while a sync is running. `refresh` asks your calendars for new information. It doesn't write to any of them. Without dates it uses the window set for automatic sync, so pass `--from` and `--through` if you haven't set that up.

Filters: `--connection`, `--calendar`, `--exclude-maybe` (hides those events entirely) and the usual date options. A date filter matches any event that overlaps the range. A moved event matches its old or new time, and shows once. With no dates you see everything relevant that hasn't ended yet, not only today. A meeting that is over can't be answered, so it drops out; ask for a date range to look back at it.

The first time Calopod sees your calendar it records a starting point, so you won't get a flood of old changes. Invitations you haven't answered still show up. Activity keeps up to 90 days and 1,000 changes per account.

If a calendar couldn't be reached, the inbox says its view is stale or incomplete. A stale view can't tell you there are no conflicts.

## Looking at one change

```sh
calopod inbox inspect 'EVENT_ID:REVISION'
calopod inbox acknowledge 'EVENT_ID:REVISION'
```

Use `--ids` to see these IDs. `acknowledge` marks that one change as seen on your Mac. It never sends a reply, and it doesn't hide an unanswered invitation, a Maybe, a newer edit or a real conflict.

## Reviewing and replying

```sh
calopod inbox review
calopod inbox review --conflicts --exclude-maybe
calopod inbox review --resume
calopod inbox config --context-before-minutes 90 --context-after-minutes 90
```

Review shows one event at a time with its details, which calendar it came from, what's around it and anything it overlaps. By default it shows 90 minutes either side of the start, and conflicts are checked across the whole event. Review needs a real terminal, so it doesn't work with `--format json`.

Type a letter and press Enter:

- `y`, `n`, `m`: reply Yes, No or Maybe. This sends your answer and may notify the organizer.
- `h`: Hold. Skips the event for this session without sending or marking anything.
- `g1`, `g2`, …: jump to an event in the current conflict group. `b` goes back.
- `q` or Ctrl-C: stop. Your progress is saved, and `--resume` continues.

Only replies that are actually possible are offered. If the event changed since you opened it, you'll see the new version and choose again.

If a reply's outcome is unclear (say the network dropped), Calopod won't send it twice. It checks what happened when you resume.

At the end you get a summary that separates how many items you reviewed from how many are actually resolved, and which conflicts you created or still have. Only confirmed replies count. Set `NO_COLOR` or pass `--no-decoration` to turn off the flourishes.

In the Mac app, **Review** on the Inbox screen does the same thing in a sheet. Only the replies a calendar allows are shown. Press `Y`, `N`, `M` or `H`, `G` then a number to jump to an overlapping event, and `S` to stop. Every reply gets a confirm step that shows who is told, the answer, the account it goes through and the overlaps that would remain; press Return to send. For calendars read through the Mac's Calendar app there is no reply to send, so the sheet offers **Open in Calendar** (`O`), **Done, next** (`D`) once you have answered there, and Hold. Those events count as held, never as answered, and show up again in the next review. Closing the sheet keeps your progress, and **Resume** continues it, checking any unclear reply first.

## Who can reply

Replies work for Google and Microsoft, on your main calendar for the account, when you're the invitee. They don't work for:

- events you organize
- shared or someone else's calendars
- the whole series of a recurring event (you reply per occurrence)
- calendars read only through the Mac's Calendar app. Reply in the Calendar app, then refresh.

Google asks to notify guests. Microsoft asks for a response to be sent to the organizer. Whether the organizer actually gets an email depends on their settings, and Calopod can only confirm that your answer was recorded.

Microsoft can't guarantee a reply wasn't overtaken by an edit made a moment earlier. That's a small window, but it exists.

Copies Calopod made are left out of the inbox. That includes a copy read back through a second connection to the same calendar, when it sits at the same time as an event Calopod copies, has the title the copy would have and has no guests.
