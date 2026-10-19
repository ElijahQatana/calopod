# Releasing the iPhone app

For maintainers. A TestFlight build is made by hand: the project does not sign, archive or upload anything on its own, and uploading is a manual step by the maintainer. Identifiers below in capitals are placeholders. Keep your real team id, certificate details and profile out of the repository.

Before archiving, run `Scripts/check-ios.sh` from the repository root. It builds for a simulator, runs the tests and fails on warnings in our own sources.

## One-time setup

1. **App ID.** In the developer portal, register `pro.elijahquintana.calopod.ios` with iCloud (CloudKit, using the container `iCloud.pro.elijahquintana.calopod`) and Push Notifications. Time Sensitive Notifications is also enabled on the App ID, but the app does not use that entitlement yet, so leave it out of `Calopod.entitlements` until it does.
2. **Certificate.** Create an Apple Distribution certificate and install it in your Keychain.
3. **Profile.** Create an App Store profile for the App ID, using that certificate. Download it and let Xcode install it. Do not commit it; `.provisionprofile` and `.mobileprovision` files are blocked by the public-content check.
4. **App Store Connect.** Create the app record with the same bundle id. TestFlight builds attach to it.
5. **Team.** Put your team id in `Apps/iOS/Local.xcconfig`, which is not tracked:

       DEVELOPMENT_TEAM = YOUR_TEAM_ID

## Before each build

**Deploy the CloudKit schema.** A TestFlight build talks to the Production environment, and a record type that exists only in Development does not work there. Record types can't be removed from Production, so deploy only what the build reads. The current record type and fields are listed in [iPhone feed](../../docs/iphone-feed.md#for-maintainers-deploy-the-schema-first). Do this in the CloudKit Dashboard with **Deploy Schema Changes**, before the build goes to testers.

**Bump the version.** `MARKETING_VERSION` is the version people see. `CURRENT_PROJECT_VERSION` is the build number and must be higher than every build already uploaded for that version, even rejected ones. Change both in the target's build settings, and commit the change on its own.

## Archive and upload

1. Open `Apps/iOS/Calopod.xcodeproj` in Xcode, choose **Any iOS Device** as the destination and run **Product > Archive**.
2. In the Organizer, select the archive and choose **Distribute App > App Store Connect > Upload**. Let Xcode sign with the Apple Distribution certificate and the App Store profile.
3. Wait for App Store Connect to finish processing the build, then add it to a TestFlight group.

From a terminal, the same steps are `xcodebuild archive` and `xcodebuild -exportArchive` with an export options file kept outside the repository. Either way you sign in and upload yourself.

## What a build does not prove

Passing tests and a successful upload say nothing about iCloud. Before testers get a build, install it from TestFlight on a device signed in to the same iCloud account as the Mac and check that the Mac's feed shows up.
