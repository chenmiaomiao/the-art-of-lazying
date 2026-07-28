#!/bin/bash

set -euo pipefail

readonly PROFILE_NAME="optiplex-3040-macos-screen-sharing.remmina"
readonly APP_NAME="optiplex-3040-macos-screen-sharing.desktop"
readonly SERVER="192.168.1.209:5900"

[ "$(uname -s)" = "Linux" ] || {
  printf 'error: run this script on Ubuntu\n' >&2
  exit 1
}
command -v remmina >/dev/null || {
  printf 'error: Remmina is not installed\n' >&2
  printf 'install it with: sudo apt install remmina remmina-plugin-vnc\n' >&2
  exit 1
}

profile_dir="$HOME/.local/share/remmina"
app_dir="$HOME/.local/share/applications"
profile="$profile_dir/$PROFILE_NAME"
app="$app_dir/$APP_NAME"
mkdir -p "$profile_dir" "$app_dir"

password="${VNC_PASSWORD:-}"
if [ -z "$password" ]; then
  if [ ! -t 0 ]; then
    printf 'error: run interactively or provide VNC_PASSWORD for this invocation\n' >&2
    exit 1
  fi
  read -r -s -p 'macOS legacy VNC password: ' password
  printf '\n'
fi
[ -n "$password" ] || {
  printf 'error: the VNC password cannot be empty\n' >&2
  exit 1
}

encrypted_output=$(
  printf '%s\n' "$password" |
    remmina --encrypt-password 2>&1 ||
    true
)
encrypted_password=$(
  printf '%s\n' "$encrypted_output" |
    sed -n 's/^Encrypted password: //p' |
    tail -n 1
)
unset password VNC_PASSWORD
[ -n "$encrypted_password" ] ||
  {
    printf '%s\n' "$encrypted_output" >&2
    printf 'error: Remmina did not encrypt the VNC password\n' >&2
    exit 1
  }

cat > "$profile" <<EOF
[remmina]
name=OptiPlex 3040 macOS - Screen Sharing
group=OptiPlex
protocol=VNC
server=$SERVER
username=
password=$encrypted_password
disablepasswordstoring=0
disableclipboard=0
disableencryption=1
quality=9
resolution_mode=2
scale=1
viewmode=1
window_maximize=1
disableserverinput=0
viewonly=0
ssh_tunnel_enabled=0
EOF
unset encrypted_output encrypted_password
chmod 600 "$profile"

cat > "$app" <<EOF
[Desktop Entry]
Type=Application
Name=OptiPlex 3040 macOS
Comment=Control the OptiPlex 3040 Monterey desktop
Icon=org.remmina.Remmina
Exec=remmina -c $profile
Terminal=false
Categories=Network;RemoteAccess;
StartupNotify=true
EOF
chmod 755 "$app"
update-desktop-database "$app_dir" 2>/dev/null || true

rm -f \
  "$HOME/.local/bin/optiplex-3040-macos-vnc" \
  "$HOME/.vnc/optiplex-3040-macos.pass"

printf 'Created auto-fit Remmina profile: %s (mode 600)\n' "$profile"
printf 'Created application launcher: %s\n' "$app"
printf 'The profile uses password-only VNC and shares the visible Mac desktop.\n'
