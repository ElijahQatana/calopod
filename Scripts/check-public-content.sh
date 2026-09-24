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
    *.env|*.log|*.pem|*.key|*.p12|*.mobileprovision)
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

grep -Eio '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' "$added_text" \
  | grep -Eiv '@(example\.(com|org|net)|users\.noreply\.github\.com)$' \
  > "$scan_dir/unapproved-emails" || true

if [ -s "$scan_dir/unapproved-emails" ]; then
  echo "Found an email address outside the approved example and noreply domains." >&2
  exit 1
fi

echo "Staged public-content checks passed."
