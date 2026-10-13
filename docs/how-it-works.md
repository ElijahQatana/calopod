# How it works

Notes for people reading or changing the code.

## Layout

| Target | Job |
|---|---|
| `CalopodDomain` | Shared types and rules. |
| `CalopodProviders` | Provider-neutral event types, ownership markers, HTTP and OAuth helpers. |
| `CalopodGoogle`, `CalopodMicrosoft`, `CalopodEventKit` | One adapter per provider. |
| `CalopodStore` | SQLite (GRDB) state and Keychain secrets. |
| `CalopodSync` | Planning and reconciling copies, availability, the inbox. |
| `CalopodRuntime` | Shared sync runner, process lock, background agent loop. |
| `CalopodCommands` | The `calopod` command tree. |
| `CalopodCLI`, `CalopodAgent`, `CalopodEventKitHost` | The executables. |

macOS grants Calendar access per app, so EventKit work runs in a small signed helper (`CalopodEventKitHost`). The CLI and the agent call it and read back JSON.

## Ownership

Every copy Calopod writes carries a small signed marker (a Google extended property, a Microsoft open extension, or a `calopod://managed/...` URL on EventKit). It records the Arm, the source and the Rule, plus an HMAC made with a random key kept in the Keychain.

Calopod only updates or deletes an event whose marker verifies and matches what it expected. A row in the database is never enough on its own. If a marker is missing, bad, or points elsewhere, the event is left alone and reported.

Each copy has a stable mirror key, a hash of the Arm and the source event. Edits and Rule changes update the same copy rather than making a new one. Google uses it as the event ID, Microsoft as the transaction ID. EventKit can't choose IDs, so each EventKit target has one preferred writer, and a repair pass removes verified duplicates.

Rules in short:

- Creates stop if an existing copy might already represent the source.
- Updates and deletes stop unless ownership is proven.
- A source that vanished during an incomplete read is not treated as deleted.
- Titles, attendees and locations are never used to work out identity.
- On EventKit, a marker only counts if the event's ID matches the one Calopod stored. A copied marker, a missing record or a changed ID blocks the apply and is reported. Markers also sign the target calendar (version 2); version 1 markers on known copies still verify.
- Duplicate repair keeps one deterministic survivor and only considers verified copies in the target calendar.

## EventKit all-day events

Calendar returns the end of an all-day event as 23:59:59 on its last day, and treats a write of the following midnight as one extra day. Calopod converts at both boundaries: on read it moves a last-second end to the next local midnight, and on write it converts back. Timed events and ends that are already midnight are left alone. Conversion uses calendar-day arithmetic, so 23- and 25-hour daylight-saving days work.

## Source identity

A source event is identified by provider, account, calendar, event ID and, for recurring events, the original occurrence date, not its current start time. So moving one occurrence updates that occurrence only.

## Provider differences

| | Google | Microsoft | EventKit |
|---|---|---|---|
| Changes | Updated-since watermark per window | Delta links per calendar and window | Refetch the window |
| Safe retries | Deterministic event ID, ETag checks | Transaction ID, change key | Preferred writer, duplicate repair |
| IDs | Event ID | Immutable event ID | Item ID plus external ID and occurrence |

EventKit change notifications say something changed, not what, so Calopod always refetches a bounded range.

## Local state and secrets

SQLite holds the settings, cached events (including titles, notes, attendees and private events), copy mappings, run history and the inbox's response history. It's owner-only but not encrypted. Backups are sealed with AES-GCM using a random key in the Keychain (`BackupEncryption`), and restore decrypts them into a staging file before the usual checks. It never holds tokens, passwords or the ownership key. Those live in the Keychain, and secrets are never taken as command arguments.

The event cache is stored per account, calendar and time window. A cursor only advances in the same transaction that saves the events it covers. Malformed or out-of-range events are dropped and only counted.

The database uses WAL with a two-second busy timeout. Writers (sync, refresh, review, backup) share an exclusive lock, so only one runs at a time. Cached readers take a shared lock that doesn't block sync but does block restore. Completed sync runs older than 90 days are pruned at the start of each sync, along with deletion records once the source has come back. Anything unfinished or unresolved is kept.

Migrations run in order, in transactions, and a failed one leaves the old schema intact. If the database is lost, a full read plus the markers on the target calendars can rebuild most of it. Sign-ins would need to be redone.

## Privacy rules for contributors

- Tests and examples use made-up data and reserved domains like `example.com`.
- Logs and diagnostics use fixed categories and local IDs, never names, event content, URLs or paths.
- Busy copies are built without the source details, before anything else sees them.

## Not done yet

ICS feeds, a Mac app, an iPhone app, a conflict-resolution screen, and automatic declines.
