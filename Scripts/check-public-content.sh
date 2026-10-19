#!/bin/sh

set -eu

scan_dir=$(mktemp -d "${TMPDIR:-/tmp}/calopod-public-check.XXXXXX")
trap 'rm -rf "$scan_dir"' EXIT

staged_files="$scan_dir/staged-files"
added_text="$scan_dir/added-text"

git diff --cached --name-only --diff-filter=ACMR > "$staged_files"

if [ ! -s "$staged_files" ]; then
  echo "No staged files to check."
  exit 0
fi

while IFS= read -r staged_file; do
  case "$staged_file" in
    *.env|*.log|*.pem|*.key|*.p12|*.mobileprovision|*.provisionprofile)
      echo "Blocked a file type that may contain private data: $staged_file" >&2
      exit 1
      ;;
    *.ics|*.sqlite|*.sqlite3|*.db)
      case "$staged_file" in
        Tests/Fixtures/Synthetic/*) ;;
        *)
          echo "Calendar and database fixtures must live under Tests/Fixtures/Synthetic: $staged_file" >&2
          exit 1
          ;;
      esac
      ;;
    *.xcconfig)
      if git show ":$staged_file" | grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[^[:space:]/]'; then
        echo "Signing team settings belong in an untracked Local.xcconfig: $staged_file" >&2
        exit 1
      fi
      ;;
  esac
done < "$staged_files"

git diff --cached --no-ext-diff --unified=0 -- . ':!Scripts/check-public-content.sh' \
  | sed -n '/^+[^+]/s/^+//p' > "$added_text"

if grep -Eiq '(/Users/|/home/)[^[:space:]]+' "$added_text"; then
  echo "Found a local home-directory path in staged content." >&2
  exit 1
fi

if grep -Eiq '(gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$added_text"; then
  echo "Found content that resembles a credential or private key." >&2
  exit 1
fi

# Image names such as background@2x.png are not addresses.
grep -Eio '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "$added_text" \
  | grep -Eiv '@[0-9]+x\.[[:alpha:]]+$' \
  | grep -Eiv '@(example\.(com|org|net)|users\.noreply\.github\.com)$' \
  > "$scan_dir/unapproved-emails" || true

if [ -s "$scan_dir/unapproved-emails" ]; then
  echo "Found an email address outside the approved example and noreply domains." >&2
  exit 1
fi

# Apple team ids, as a signing setting or in front of a bundle id.
if grep -Eq '(DEVELOPMENT_TEAM|[Tt]eam[ -]?(ID|Identifier))[^A-Za-z0-9]{0,6}[A-Z0-9]{10}([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9])[A-Z0-9]{10}\.(pro|com)\.[a-z]+' "$added_text"; then
  echo "Found what looks like an Apple team identifier." >&2
  exit 1
fi

# A certificate hash is 40 hex digits. Commit ids look the same, so only look in the iPhone app.
git diff --cached --no-ext-diff --unified=0 -- Apps/iOS \
  | sed -n '/^+[^+]/s/^+//p' > "$scan_dir/ios-added-text"
if grep -Eq '(^|[^0-9A-Fa-f])[0-9A-Fa-f]{40}([^0-9A-Fa-f]|$)' "$scan_dir/ios-added-text"; then
  echo "Found a 40-digit hex value, which may be a certificate hash, in the iPhone app." >&2
  exit 1
fi

echo "Staged public-content checks passed."
