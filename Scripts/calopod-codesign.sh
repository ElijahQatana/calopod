# Shared signing commands for the local build scripts and the release signer.
# Source this file; it only defines functions.

# calopod_sign_item CODESIGN IDENTITY PATH [codesign options...]
# A real identity gets the hardened runtime and a secure timestamp, the same shape as a release.
# The ad hoc identity "-" stays a plain signature so local builds work offline.
calopod_sign_item() {
  sign_tool=$1
  sign_identity=$2
  sign_path=$3
  shift 3
  if [ "$sign_identity" = "-" ]; then
    "$sign_tool" --force --sign - "$@" "$sign_path" > /dev/null 2>&1
  else
    "$sign_tool" --force --sign "$sign_identity" --options runtime --timestamp "$@" "$sign_path" > /dev/null 2>&1
  fi
}

# calopod_show_signature CODESIGN PATH
# Prints the signature flags, team and entitlements so a build shows what it made.
calopod_show_signature() {
  echo "Signature of $(basename "$2")"
  "$1" -dvv "$2" 2>&1 | sed -n -e 's/^Authority=\(Developer ID Application\)/  \1/p' \
    -e 's/^CodeDirectory .*\(flags=[^ ]*\).*/  \1/p' -e 's/^\(TeamIdentifier=.*\)/  \1/p' \
    -e 's/^\(Timestamp=.*\)/  \1/p' -e 's/^\(Signature=.*\)/  \1/p'
  echo "  entitlements:"
  "$1" -d --entitlements :- "$2" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g; s/^/    /'
}
