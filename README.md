# Calopod 🦑

*One schedule. Many calendars.*

Calopod connects separate calendar accounts, keeps them cross-blocked, publishes one complete Main calendar, and derives Availability across every selected source.

## The shape of it

- **Connections** are calendar accounts or sources.
- **Arms** are sync and publish relationships.
- **Rules** control what an Arm may expose.
- **Main calendar** is the complete unified view.
- **Availability** is derived across the selected sources.

The first release is a local command-line utility for macOS. It starts with the calendar accounts already configured on the Mac, so normal local use does not require a Google Cloud project or Microsoft Entra registration. A background Mac service, native Mac app, and manual-sync iPhone app follow from the same shared core.

The complete product boundary is in [PROJECT_CHARTER.md](PROJECT_CHARTER.md).

## Development

Calopod requires Swift 6.1 or newer. Build and test the shared workspace from the repository root:

```sh
swift build
swift test
```

Start with [Calendars on this Mac](docs/CALENDARS_ON_THIS_MAC.md). Direct Google and Microsoft connections are also available for provider development and advanced setups; those paths currently require a developer-owned client ID. Setup lives in [docs/GOOGLE_CALENDAR.md](docs/GOOGLE_CALENDAR.md) and [docs/MICROSOFT_CALENDAR.md](docs/MICROSOFT_CALENDAR.md).

The CLI and agent targets share the same core:

```sh
swift run calopod sync --dry-run --day 2026-09-25
swift run calopod main inspect
swift run calopod-agent
```

Dry-run sync refreshes configured Arm sources and managed targets, then reports deterministic creates, updates, removals, repairs, and no-ops without writing calendar events. Apply mode verifies signed ownership, excludes mirrors from source ingestion, rereads after writes, and repairs verified duplicates. EventKit Arms use one explicit preferred writer.

The complete command tree, date-range behavior, output envelope, and exit codes are documented in [docs/COMMAND_LINE.md](docs/COMMAND_LINE.md).
Combined Busy and Free interval behavior is documented in [docs/AVAILABILITY.md](docs/AVAILABILITY.md).
