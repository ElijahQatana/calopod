# Contributing

Thanks for helping with Calopod. Everything in this repository is public, so keep personal data out of it.

## Start with an issue

For anything bigger than a small fix, open an issue first so we can agree on the approach. Keep each pull request focused on one change, and link the issue, for example `Closes #123`.

## Protect personal information

Assume source files, comments, tests, fixtures, documentation, commit metadata, issues, pull requests, screenshots, and copied terminal output will become public.

- Use synthetic people, accounts, organizations, calendars, events, locations, meeting links, identifiers, and schedules.
- Use reserved domains such as `example.com` in examples.
- Never build fixtures by editing or redacting a real calendar export.
- Do not commit credentials, tokens, cookies, authorization codes, private feed URLs, local usernames, home-directory paths, or device identifiers.
- Review screenshots and logs before attaching them to an issue or pull request.
- Keep diagnostic output redacted by default.

If realistic data is required to reproduce a bug, create a fresh synthetic case that preserves only the relevant behavior.

## Git identity

Commit with an identity you're happy to make public. A GitHub noreply address works if you'd rather not share your email.

Check the effective identity before committing:

```sh
git config --local --get user.name
git config --local --get user.email
```

## Before committing

Stage only the intended files, then run:

```sh
Scripts/check-public-content.sh
git diff --cached --check
```

Keep the build free of compiler warnings. `Scripts/check-build-warnings.sh` builds in a temporary folder and fails on any warning from `Sources` or `Tests`. It is slow, so run it by hand when you touch build-sensitive code and before a release.

Read the staged diff before committing. Automated checks catch common mistakes, but they do not replace a manual review.

## Continuous integration

Pull requests and pushes to main run `swift build` and `swift test --disable-sandbox` on a macOS runner (see `.github/workflows/ci.yml`). Pull requests also run the public-content check against their diff. The workflow uses no secrets and read-only permissions.

## Pull requests

Write a short explanation of what changed and why. Include the verification performed and call out any known limitation or follow-up. Resolve review conversations before merging.
