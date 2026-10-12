# Install

Calopod installs for your own user account only. Don't use `sudo`.

You need an Apple Silicon Mac on macOS 14 or newer.

## Install from a release

1. Download the ZIP and its `.sha256` file from the release page.
2. Check and unpack it:

```sh
shasum -a 256 -c Calopod-0.1.1-macos-arm64.zip.sha256
ditto -x -k Calopod-0.1.1-macos-arm64.zip extracted
cd extracted/Calopod-0.1.1-macos-arm64
```

3. Run the installer:

```sh
./install
```

A fresh install syncs every 10 minutes with up to 30 seconds of random jitter, looking back 1 day and ahead 30 days. Upgrades keep the schedule you already have. To change a value, add `--interval-seconds`, `--jitter-seconds`, `--lookback-days` or `--horizon-days`, for example `./install --horizon-days 60`.

The installer links `calopod`, `calopod-setup` and `calopod-uninstall` into `~/.local/bin`. Add that folder to your `PATH` if it isn't there already. It doesn't edit your shell files and it doesn't start automatic sync.

## Set up

```sh
calopod-setup
```

Setup asks you to choose a mode, then asks for Calendar access and shows your calendars.

- **Basic** sets up one Main calendar (everything, with full details) and one Busy calendar (times only). Use new, empty calendars as the targets.
- **Custom Arms** lets you pick the sources, destination and Rule for each route, using calendars you already have. See [Copying between existing calendars](using-calopod.md#copying-between-existing-calendars).

Skip the question with `calopod-setup --basic` or `calopod-setup --arms`. Setup finishes with a dry run and a health check, and leaves automatic sync off until you turn it on.

If you stop part way, setup keeps what you've finished and picks up where you left off.

## Calendar permission

The first time, macOS asks whether Calopod may access your calendars. Choose full access, which is the only level that lets Calopod read event details. You can change it later in System Settings, under Privacy & Security, then Calendars.

## Upgrade

```sh
calopod agent disable
./install
calopod agent enable
```

Your settings and sign-ins are kept. If you want a restore point first, make a [backup](troubleshooting.md#back-up-and-restore).

## Remove

```sh
calopod-uninstall
```

This removes the commands and the background service. It keeps your settings and Keychain items so a later install can pick up where you left off.

## Build from source

You need Swift 6.1 or newer.

```sh
swift build
./Scripts/build-eventkit-host.sh   # the small app macOS asks for Calendar access
swift run calopod connection add mac
```

To run the background service from a checkout:

```sh
Scripts/calopod-service.sh build
Scripts/calopod-service.sh install --interval-seconds 600 --jitter-seconds 30 --lookback-days 1 --horizon-days 30
Scripts/calopod-service.sh load
```

Use `unload` to stop it and `remove` to uninstall it. Source builds are signed ad hoc, so macOS may ask for Calendar access again after you rebuild.

If you connect Google or Microsoft directly, export their client IDs before you install the service. See [Google and Microsoft accounts](google-and-microsoft.md).
