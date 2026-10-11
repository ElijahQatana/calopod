# Contributing

Calopod is intended to become an open-source project. Work in this repository should be safe to publish from the moment it is committed.

## Start with an issue

Every change starts with a GitHub issue assigned to a milestone. Keep the change focused on that issue and use a closing reference in the pull request, such as `Closes #123`.

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

Configure an identity approved for public use in this repository. Prefer a GitHub-provided noreply address when a personal email should remain private.

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

Read the staged diff before committing. Automated checks catch common mistakes, but they do not replace a manual review.

## Continuous integration

Pull requests and pushes to main run `swift build` and `swift test --disable-sandbox` on a macOS runner (see `.github/workflows/ci.yml`). Pull requests also run the public-content check against their diff. The workflow uses no secrets and read-only permissions.

## Pull requests

Write a short explanation of what changed and why. Include the verification performed and call out any known limitation or follow-up. Resolve review conversations before merging.
