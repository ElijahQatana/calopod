# Releasing

For maintainers. A release is a notarized ZIP for Apple Silicon Macs, with an optional disk image for the app.

## Identifiers

| Part | Identifier |
|---|---|
| Main app (reserved) | `pro.elijahquintana.calopod` |
| Calendar helper | `pro.elijahquintana.calopod.eventkit-host` |
| Background service | `pro.elijahquintana.calopod.agent` |

The helper's bundle ID and the service's associated bundle ID must match. Calendar permission belongs to the helper's ID and signing identity, so keep both stable between releases.

The app icon source is `Support/EventKitHost/Calopod.icon`.

## Before you build

Run `Scripts/check-build-warnings.sh`. It builds everything, tests included, in a throwaway folder and fails on any compiler warning from our own `Sources` or `Tests`. It takes a few minutes, so it is not part of `swift test`. A warning from code we cannot change can go in `Scripts/build-warnings-ignore.txt`, with a note on why.

## Local build

```sh
Scripts/build-calopod-release.sh
```

This writes the bundle, a ZIP and a `.sha256` file under `.build/releases`. It's ad-hoc signed, which is fine for testing and not for sharing.

## Signed build

Store notarization credentials once. `notarytool` asks for them and keeps them in your Keychain:

```sh
xcrun notarytool store-credentials calopod-preview-notary
```

Then build with your Developer ID certificate hash:

```sh
signing_identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')
Scripts/build-calopod-release.sh \
  --output-directory "$(mktemp -d "$PWD/.build/calopod-release.XXXXXX")" \
  --signing-identity "$signing_identity" \
  --notary-profile calopod-preview-notary
```

The script builds, signs with Hardened Runtime, submits for notarization, staples the helper app and writes fresh checksums. Don't put your Apple ID, team ID or certificate details in the repo or release notes, and don't share verbose `codesign` output.

Check before publishing:

```sh
shasum -a 256 -c Calopod-*.zip.sha256
codesign --verify --strict --check-notarization -R=notarized Calopod-*/bin/calopod
xcrun stapler validate -q "Calopod-*/eventkit-host/Calopod EventKit Host.app"
```

## iPhone feed signing

The iPhone feed needs the app to use iCloud, which needs a provisioning profile. Create a Developer ID profile for the app's App ID with iCloud (CloudKit) and the container `iCloud.pro.elijahquintana.calopod`, download it, and pass it to the app build:

```sh
CALOPOD_SIGN_IDENTITY="$signing_identity" \
CALOPOD_PROVISIONING_PROFILE=/path/to/Calopod.provisionprofile \
  Scripts/build-calopod-mac-app.sh
```

The script copies the profile to `Contents/embedded.provisionprofile` and signs the app with the iCloud entitlements, taking the app and team identifiers from the profile. Only the app's main executable can hold these entitlements, so the agent and the command are signed as before. Without `CALOPOD_PROVISIONING_PROFILE` the app is signed with no iCloud keys, and the feed's switch in Settings stays off. A profile needs a real signing identity, not ad hoc.

Deploy the record type to the Production schema before the first release that uses it. The list is in [iPhone feed](iphone-feed.md). A signed, notarized app can't use the Development environment.

## iPhone app

The iPhone app has its own steps for making a TestFlight build, in [Apps/iOS/RELEASING.md](../Apps/iOS/RELEASING.md). Uploading is done by hand.

## Disk image

The Mac app ships as a drag-to-install disk image. Build the app signed, then package it:

```sh
signing_identity=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')
CALOPOD_BUILD_CONFIGURATION=release CALOPOD_SIGN_IDENTITY="$signing_identity" Scripts/build-calopod-mac-app.sh
Scripts/make-calopod-dmg.sh --identity "$signing_identity"
```

The script checks the app first and refuses one that is unsigned, ad hoc, missing the Hardened Runtime or missing the Calendar entitlement on the app or the helper. `--allow-adhoc` skips that for a local test and prints a warning. It writes `dist/Calopod-<version>.dmg` and a `.sha256` file, signs the image with `--identity` (default `CALOPOD_SIGN_IDENTITY`) and runs `hdiutil verify`. The window layout is written to the image directly, so no Finder session is opened. Window size, background size and icon positions come from `Scripts/dmg/layout.json`. The image holds only the app and the Applications link; the hint about the command line is part of the background. The first run installs a pinned copy of dmgbuild into `.build/dmg-venv`, which needs network access once.

`Scripts/build-calopod-release.sh --dmg` builds the app and the image after the ZIP, with the same signing identity.

Notarizing is a separate step and uses your own keychain profile. Run it yourself, or pass `--notarize PROFILE` to the script:

```sh
xcrun notarytool submit dist/Calopod-*.dmg --keychain-profile PROFILE --wait
xcrun stapler staple dist/Calopod-*.dmg
xcrun stapler validate dist/Calopod-*.dmg
spctl -a -t open --context context:primary-signature -vv dist/Calopod-*.dmg
shasum -a 256 dist/Calopod-*.dmg > dist/Calopod-<version>.dmg.sha256
```

The script's tests and the release builds never notarize. Stapling changes the file, so refresh the checksum afterwards (the script does this itself with `--notarize`). Publish the image and its `.sha256` only after you have opened it on a clean Mac.

## Publish

Tag the reviewed commit and upload only the ZIP and its `.sha256`. Keep the notes short: supported Macs, a link to [Install](install.md), and where to report problems.

## Clean-Mac check

On a Mac with no Calopod state, install the release ZIP, run `calopod-setup`, sync into two new empty calendars, turn on automatic sync, then reinstall and uninstall. Confirm each step works and `calopod doctor` stays healthy. Share results only as pass or fail with generic counts.
