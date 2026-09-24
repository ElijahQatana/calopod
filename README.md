# Calopod 🦑

*One schedule. Many calendars.*

Calopod connects separate calendar accounts, keeps them cross-blocked, publishes one complete Main calendar, and derives Availability across every selected source.

## The shape of it

- **Connections** are calendar accounts or sources.
- **Arms** are sync and publish relationships.
- **Rules** control what an Arm may expose.
- **Main calendar** is the complete unified view.
- **Availability** is derived across the selected sources.

The first release is a local command-line utility for macOS. A background Mac service, native Mac app, and manual-sync iPhone app follow from the same shared core.

Calopod is in its foundation stage. The complete product boundary is in [PROJECT_CHARTER.md](PROJECT_CHARTER.md).

## Development

Calopod requires Swift 6.1 or newer. Build and test the shared workspace from the repository root:

```sh
swift build
swift test
```

Read-only Google and Microsoft connections are available. Setup lives in [docs/GOOGLE_CALENDAR.md](docs/GOOGLE_CALENDAR.md) and [docs/MICROSOFT_CALENDAR.md](docs/MICROSOFT_CALENDAR.md). The two executable targets share the same core:

```sh
swift run calopod sync --dry-run
swift run calopod-agent
```

The placeholder reports zero operations until the first provider vertical slice is added.

The complete command tree, date-range behavior, output envelope, and exit codes are documented in [docs/COMMAND_LINE.md](docs/COMMAND_LINE.md).
