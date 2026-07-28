#!/bin/bash

set -euo pipefail

readonly EXPECTED_USER="lachlan"
readonly ROYAL_APP="/Applications/Royal TSX.app"
readonly RDP_HOST="192.168.1.227"
readonly RDP_PORT="3391"
readonly RDP_USER="lachlan"
readonly KEYCHAIN_SERVICE="OptiPlex-7090-GNOME-RDP"

usage() {
  cat <<'EOF'
Usage:
  install-optiplex-3040-rdp-launcher-macos.sh --password

Run on the OptiPlex 3040 Mac as lachlan. The script reads one RDP password
from the terminal without echo, stores it in the login Keychain, and creates
a Desktop launcher for the OptiPlex 7090's current GNOME desktop.
EOF
}

[ "$(uname -s)" = "Darwin" ] || {
  printf 'error: run this script on macOS\n' >&2
  exit 1
}
[ "$(id -un)" = "$EXPECTED_USER" ] || {
  printf 'error: run this script as %s\n' "$EXPECTED_USER" >&2
  exit 1
}
[ "${1:-}" = "--password" ] || {
  usage
  exit 2
}
[ -d "$ROYAL_APP" ] || {
  printf 'error: Royal TSX is not installed\n' >&2
  exit 1
}

printf 'RDP password for %s@%s: ' "$RDP_USER" "$RDP_HOST"
IFS= read -r -s rdp_password
printf '\n'
[ -n "$rdp_password" ] || {
  printf 'error: password must not be empty\n' >&2
  exit 1
}

security add-generic-password \
  -U \
  -a "$RDP_USER" \
  -s "$KEYCHAIN_SERVICE" \
  -w "$rdp_password"
unset rdp_password

stage=$(mktemp -d "${TMPDIR:-/tmp}/rdp-launcher.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
source_file="$stage/launcher.applescript"
launcher="$HOME/Desktop/OptiPlex 7090 - Current Desktop.app"

cat > "$source_file" <<'EOF'
use framework "Foundation"
use scripting additions

on percentEncode(inputText)
  set allowedText to "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  set allowedCharacters to current application's NSCharacterSet's characterSetWithCharactersInString:allowedText
  set inputString to current application's NSString's stringWithString:inputText
  return (inputString's stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters) as text
end percentEncode

on run
  set rdpPassword to do shell script "/usr/bin/security find-generic-password -w -a lachlan -s OptiPlex-7090-GNOME-RDP"
  set encodedPassword to my percentEncode(rdpPassword)
  set rdpPassword to missing value
  set connectionURL to "rtsx://rdp%3A%2F%2F192.168.1.227%3A3391?using=adhoc&action=connect&username=lachlan&password=" & encodedPassword & "&property_Name=OptiPlex%207090%20Current%20Desktop&property_ColorDepth=32"
  open location connectionURL
end run
EOF

rm -rf "$launcher"
osacompile -o "$launcher" "$source_file"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$ROYAL_APP"

printf 'Created: %s\n' "$launcher"
printf 'Target: %s:%s (current GNOME desktop)\n' "$RDP_HOST" "$RDP_PORT"
