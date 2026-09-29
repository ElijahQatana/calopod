# Calopod CLI preview

This bundle installs Calopod for the signed-in user. It does not require or
accept root access.

Install the release without loading the background service:

```sh
./install \
  --interval-seconds 600 \
  --jitter-seconds 30 \
  --lookback-days 1 \
  --horizon-days 30
```

The installer adds `calopod`, `calopod-setup`, and `calopod-uninstall` links under
`~/.local/bin`. Add that directory to `PATH` if it is not already available in
your shell.

Configure Calendars on this Mac, Main, Busy, and automatic sync:

```sh
calopod-setup
```

The setup command asks before creating missing state or enabling automatic
sync. Use fresh empty target calendars when starting with new state.

Remove installed executables and service files while preserving SQLite state
and Keychain material:

```sh
calopod-uninstall
```

The first technical preview supports Apple Silicon Macs running macOS 14 or
newer. The payload is ad-hoc signed for packaging validation; release signing
and notarization are performed separately.
