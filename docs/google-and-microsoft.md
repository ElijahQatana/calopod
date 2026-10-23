# Google and Microsoft accounts

Most people don't need this page. If your Google or Microsoft account is already in the Mac's Calendar app, Calopod reads it from there with no extra setup.

Connect directly if you want invitation replies for those accounts, or want to avoid the Calendar app. This path is more work today: you register your own app, because Calopod doesn't ship shared sign-in credentials.

Don't connect the same account both ways. Calopod warns when it spots that.

## Google

1. In Google Cloud, create or pick a project and turn on the Google Calendar API.
2. Set up the OAuth consent screen for your account.
3. Create an OAuth client of type **Desktop app**, and copy the client ID and client secret. Google asks for the secret when Calopod trades the sign-in for tokens.
4. Export both and connect:

```sh
export CALOPOD_GOOGLE_CLIENT_ID='your-desktop-client-id'
export CALOPOD_GOOGLE_CLIENT_SECRET='your-desktop-client-secret'
calopod connection add google
calopod calendars
calopod calendars --connection CONNECTION_ID --select CALENDAR_ID
```

Your browser opens for sign-in and returns to a temporary address on your own machine (`127.0.0.1`). Tokens go straight into the Keychain and are never written to the database or taken as command arguments.

## Microsoft

1. In Microsoft Entra, create an app registration. Choose the account types you need, such as work and personal accounts together.
2. Under Authentication, add the **Mobile and desktop applications** platform, add `http://localhost` as the redirect URI, and allow public client flows.
3. Add the delegated Microsoft Graph permission `Calendars.ReadWrite`.
4. Copy the application (client) ID. Don't create a secret.

```sh
export CALOPOD_MICROSOFT_CLIENT_ID='your-public-client-id'
export CALOPOD_MICROSOFT_TENANT='your-tenant-id'   # optional, defaults to "common"
calopod connection add microsoft
```

## Automatic sync with these accounts

The background service can't see your shell. Export the client ID, and the Google client secret if you use Google, before you install or reinstall the service, and the installer will copy them in. If the ID is missing, `calopod doctor` reports a `client-id` problem. These are app credentials, not sign-in tokens, and tokens never go in the service file.

If you connected with an older, read-only version, remove the connection and add it again before using it for writing.

## Disconnect

```sh
calopod connection remove CONNECTION_ID
```

This deletes the Keychain sign-in and the local data for that account.

## What gets read

Only the time range you ask for is read, and cached events are the minimum Calopod needs. Google recurring events are expanded into single occurrences. For Microsoft, an expired change token just triggers a fresh read of that range. Events carrying a Calopod marker are never treated as originals.
