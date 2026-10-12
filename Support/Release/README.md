# Calopod CLI preview

This bundle installs Calopod for the signed-in user. It does not require or
accept root access.

Install the release without loading the background service:

```sh
./install
```

Fresh installs use a 600-second interval, 30-second jitter, 1-day lookback,
and 30-day horizon. Upgrades preserve the schedule. Each scheduling flag is
an optional override; run `./install --help` for the flags.

The installer adds `calopod`, `calopod-setup`, and `calopod-uninstall` links under
`~/.local/bin`. Add that directory to `PATH` if it is not already available in
your shell.

Choose Basic or Custom Arms for Calendars on this Mac:

```sh
calopod-setup
```

Basic configures one full-details Main calendar and one Busy-only calendar,
using fresh empty targets. Custom Arms configures individual routes between
existing calendars. Use `--basic` or `--arms` to skip the choice. Setup asks
before creating missing state and leaves automatic sync disabled until a
manual sync is verified. New state must not reuse copies from an old setup.

Remove installed executables and service files while preserving SQLite state
and Keychain material:

```sh
calopod-uninstall
```

The first technical preview supports Apple Silicon Macs running macOS 14 or
newer. A distribution bundle contains a `SIGNING` marker, Developer ID-signed
executables, a notarized EventKit host, and checksums created after its ticket
is stapled. A bundle without that marker is a local development build.
