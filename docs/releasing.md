# Releasing

For maintainers. A release is a notarized ZIP for Apple Silicon Macs.

## Identifiers

| Part | Identifier |
|---|---|
| Main app (reserved) | `pro.elijahquintana.calopod` |
| Calendar helper | `pro.elijahquintana.calopod.eventkit-host` |
| Background service | `pro.elijahquintana.calopod.agent` |

The helper's bundle ID and the service's associated bundle ID must match. Calendar permission belongs to the helper's ID and signing identity, so keep both stable between releases.

The app icon source is `Support/EventKitHost/Calopod.icon`.

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

## Publish

Tag the reviewed commit and upload only the ZIP and its `.sha256`. Keep the notes short: supported Macs, a link to [Install](install.md), and where to report problems.

## Clean-Mac check

On a Mac with no Calopod state, install the release ZIP, run `calopod-setup`, sync into two new empty calendars, turn on automatic sync, then reinstall and uninstall. Confirm each step works and `calopod doctor` stays healthy. Share results only as pass or fail with generic counts.
