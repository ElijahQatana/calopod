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

The installer adds `calopod` and `calopod-uninstall` links under
`~/.local/bin`. Add that directory to `PATH` if it is not already available in
your shell.

Enable automatic sync after configuring Connections, selected calendars, and
Arms:

```sh
calopod agent enable
calopod agent status
```

Remove installed executables and service files while preserving SQLite state
and Keychain material:

```sh
calopod-uninstall
```

The first technical preview supports Apple Silicon Macs running macOS 14 or
newer. The payload is ad-hoc signed for packaging validation; release signing
and notarization are performed separately.
