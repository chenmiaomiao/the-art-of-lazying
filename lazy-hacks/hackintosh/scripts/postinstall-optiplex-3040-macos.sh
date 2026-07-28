#!/bin/bash

set -euo pipefail

readonly EXPECTED_USER="lachlan"
readonly EXPECTED_UU_SHA256="492ab1c360fb30f471dca71d2468be93d6a76a72b7d256d911f2095f72acefdd"
readonly EXPECTED_UU_TEAM_ID="PU9BNSBJW7"
readonly PINNED_NVM_VERSION="0.40.4"
readonly NVM_ARCHIVE_SHA256="5949b50e4640f2be2263f963952673d7f1a8745a83f05365e99f032fe78307fd"
readonly NODE_VERSION="22"

uu_package=""
authorized_key=""
peer_host=""
peer_user="$EXPECTED_USER"
set_legacy_vnc=0

usage() {
  cat <<'EOF'
Usage:
  postinstall-optiplex-3040-macos.sh \
    --uu-package /path/to/uuyc_4.33.0.pkg \
    --authorized-key /path/to/authorized_key.pub \
    --peer-host 192.168.1.227 \
    [--vnc-password]

The script is idempotent. It does not edit OpenCore, rename disks, enable
automatic login, alter TCC databases, or start a macOS upgrade.

--vnc-password securely prompts for a separate legacy VNC password. Use it
only on a trusted LAN when the client cannot negotiate Apple account
authentication. The password is never written into this script.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

append_line_once() {
  local path="$1"
  local line="$2"

  touch "$path"
  if ! grep -Fqx "$line" "$path"; then
    printf '%s\n' "$line" >> "$path"
  fi
}

stop_sudo_keepalive() {
  if [ -n "${sudo_keepalive_pid:-}" ]; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
}

enforce_uu_aqua_session() {
  local agent_plist="/Library/LaunchAgents/com.netease.uuremote.agent.plist"
  local agent_label="com.netease.uuremote.agent"
  local gui_domain
  local session_types
  local timestamp

  gui_domain="gui/$(id -u)"
  [ -f "$agent_plist" ] || fail "UU Remote LaunchAgent is missing"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent_plist")" = \
    "$agent_label" ] || fail "UU Remote LaunchAgent has an unexpected label"
  session_types=$(
    /usr/libexec/PlistBuddy \
      -c 'Print :LimitLoadToSessionType' \
      "$agent_plist"
  )
  if ! printf '%s\n' "$session_types" | grep -Fq "Aqua" ||
     printf '%s\n' "$session_types" | grep -Fq "LoginWindow"; then
    timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
    sudo cp -p \
      "$agent_plist" \
      "${agent_plist}.before-aqua-only-${timestamp}"
    sudo plutil \
      -replace LimitLoadToSessionType \
      -json '["Aqua"]' \
      "$agent_plist"
    sudo plutil -lint "$agent_plist"
  fi

  # Apple Screen Sharing may create a root loginwindow domain. Never let UU
  # attach there; one Aqua agent must own the visible user's console session.
  sudo launchctl bootout "gui/0/$agent_label" 2>/dev/null || true
  sudo launchctl bootout "user/0/$agent_label" 2>/dev/null || true
  launchctl bootout "$gui_domain/$agent_label" 2>/dev/null || true
  launchctl enable "$gui_domain/$agent_label"
  if ! launchctl bootstrap "$gui_domain" "$agent_plist" 2>/dev/null; then
    launchctl kickstart -k "$gui_domain/$agent_label"
  fi
  launchctl print "$gui_domain/$agent_label" >/dev/null
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uu-package)
      [ "$#" -ge 2 ] || fail "--uu-package requires a path"
      uu_package="$2"
      shift 2
      ;;
    --authorized-key)
      [ "$#" -ge 2 ] || fail "--authorized-key requires a path"
      authorized_key="$2"
      shift 2
      ;;
    --peer-host)
      [ "$#" -ge 2 ] || fail "--peer-host requires an address"
      peer_host="$2"
      shift 2
      ;;
    --peer-user)
      [ "$#" -ge 2 ] || fail "--peer-user requires a user"
      peer_user="$2"
      shift 2
      ;;
    --vnc-password)
      set_legacy_vnc=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -un)" = "$EXPECTED_USER" ] ||
  fail "run this script while logged in as $EXPECTED_USER"
[ -n "$uu_package" ] || fail "--uu-package is required"
[ -f "$uu_package" ] || fail "UU package is missing: $uu_package"
[ -n "$authorized_key" ] || fail "--authorized-key is required"
[ -f "$authorized_key" ] || fail "public key is missing: $authorized_key"
[ -n "$peer_host" ] || fail "--peer-host is required"

public_key=$(sed -n '1p' "$authorized_key")
case "$public_key" in
  ssh-ed25519\ *) ;;
  *) fail "the authorized key must be one Ed25519 public key" ;;
esac
[ "$(wc -l < "$authorized_key" | tr -d ' ')" -eq 1 ] ||
  fail "the authorized key file must contain exactly one line"

actual_uu_sha256=$(shasum -a 256 "$uu_package" | awk '{ print $1 }')
[ "$actual_uu_sha256" = "$EXPECTED_UU_SHA256" ] ||
  fail "UU package SHA-256 does not match the reviewed 4.33.0 package"
signature=$(pkgutil --check-signature "$uu_package" 2>&1)
printf '%s\n' "$signature" | grep -Fq "Notarization: trusted" ||
  fail "UU package is not trusted by Apple's notary service"
printf '%s\n' "$signature" | grep -Fq "($EXPECTED_UU_TEAM_ID)" ||
  fail "UU package is not signed by the reviewed NetEase team"

printf 'macOS will request the %s administrator password.\n' "$EXPECTED_USER"
sudo -v
# Long downloads and npm installs can outlive macOS's sudo timestamp. Keep the
# authenticated timestamp warm so the final service checks remain unattended.
while true; do
  sudo -n true 2>/dev/null || exit
  sleep 45
done &
sudo_keepalive_pid=$!
trap stop_sudo_keepalive EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -Fqx "$public_key" "$HOME/.ssh/authorized_keys"; then
  printf '%s\n' "$public_key" >> "$HOME/.ssh/authorized_keys"
fi

outbound_key="$HOME/.ssh/id_ed25519_optiplex_3040_macos"
if [ ! -f "$outbound_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -C \
    "lachlan@OptiPlex-3040-macOS" -f "$outbound_key"
fi
chmod 600 "$outbound_key"
chmod 644 "${outbound_key}.pub"

ssh_config="$HOME/.ssh/config"
touch "$ssh_config"
chmod 600 "$ssh_config"
if ! grep -Fq "Host optiplex-7090-ubuntu" "$ssh_config"; then
  {
    printf '\nHost optiplex-7090-ubuntu\n'
    printf '    HostName %s\n' "$peer_host"
    printf '    User %s\n' "$peer_user"
    printf '    IdentityFile ~/.ssh/id_ed25519_optiplex_3040_macos\n'
    printf '    IdentitiesOnly yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    TCPKeepAlive yes\n'
    printf '    StrictHostKeyChecking accept-new\n'
  } >> "$ssh_config"
fi

sudo systemsetup -setremotelogin on
sudo launchctl enable system/com.openssh.sshd
sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
sudo scutil --set ComputerName "OptiPlex 3040 macOS"
sudo scutil --set LocalHostName "OptiPlex-3040-macOS"
sudo scutil --set HostName "OptiPlex-3040-macOS"
sudo systemsetup -settimezone "Asia/Shanghai"
sudo pmset -a \
  sleep 0 \
  disksleep 0 \
  displaysleep 0 \
  powernap 0 \
  standby 0 \
  autopoweroff 0 \
  womp 1 \
  tcpkeepalive 1 \
  autorestart 1

kickstart="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
[ -x "$kickstart" ] || fail "Apple Remote Management kickstart tool is missing"
remote_management_marker="/Library/Application Support/Apple/Remote Desktop/RemoteManagement.launchd"
if [ ! -f "$remote_management_marker" ]; then
  # Monterey's kickstart can return an IO::File error after activation has
  # already succeeded. Accept that specific partial result only when its
  # activation marker was created.
  if ! sudo "$kickstart" -activate; then
    [ -f "$remote_management_marker" ] ||
      fail "Apple Remote Management activation failed"
  fi
fi
if ! sudo "$kickstart" \
    -configure \
    -allowAccessFor -specifiedUsers \
    -access -on \
    -users "$EXPECTED_USER" \
    -privs -all \
    -restart -agent; then
  printf 'kickstart hit Monterey user-authorization bug; using access group.\n'
fi
sudo dseditgroup \
  -o edit \
  -a "$EXPECTED_USER" \
  -t user \
  com.apple.access_screensharing
sudo dseditgroup \
  -o checkmember \
  -m "$EXPECTED_USER" \
  com.apple.access_screensharing |
  grep -Fq "yes $EXPECTED_USER is a member" ||
  fail "screen-sharing access group did not accept $EXPECTED_USER"

if [ "$set_legacy_vnc" -eq 1 ]; then
  [ -t 0 ] || fail "--vnc-password requires an interactive terminal"
  read -r -s -p 'Legacy VNC password (1-8 ASCII characters): ' legacy_vnc_password
  printf '\n'
  if LC_ALL=C printf '%s' "$legacy_vnc_password" | grep -q '[^ -~]'; then
    fail "legacy VNC password must contain only printable ASCII"
  fi
  password_length=${#legacy_vnc_password}
  if [ "$password_length" -lt 1 ] || [ "$password_length" -gt 8 ]; then
    fail "legacy VNC password must be 1-8 ASCII characters"
  fi
  sudo "$kickstart" \
    -configure \
    -clientopts \
    -setvnclegacy \
    -vnclegacy yes \
    -setvncpw \
    -vncpw "$legacy_vnc_password"
  unset legacy_vnc_password
fi

sudo "$kickstart" -restart -agent
sudo launchctl enable system/com.apple.screensharing
sudo launchctl kickstart -k system/com.apple.screensharing
sleep 1
nc -z -w 3 127.0.0.1 5900 ||
  fail "Apple Screen Sharing is not accepting local connections"

sudo defaults write \
  /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write \
  /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write \
  /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
sudo defaults write \
  /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
sudo defaults write \
  /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true

sudo installer -pkg "$uu_package" -target /
codesign --verify --deep --strict /Applications/UURemote.app
uu_team_id=$(
  codesign -dv --verbose=2 /Applications/UURemote.app 2>&1 |
    sed -n 's/^TeamIdentifier=//p' |
    head -n 1
)
[ "$uu_team_id" = "$EXPECTED_UU_TEAM_ID" ] ||
  fail "installed UU app has an unexpected Team ID: $uu_team_id"
enforce_uu_aqua_session

nvm_dir="$HOME/.nvm"
if [ ! -s "$nvm_dir/nvm.sh" ]; then
  [ ! -e "$nvm_dir" ] || fail "$nvm_dir exists but does not contain nvm.sh"
  nvm_stage=$(mktemp -d "${TMPDIR:-/tmp}/nvm-stage.XXXXXX")
  nvm_archive="$nvm_stage/nvm.tar.gz"
  curl -fL --retry 3 \
    -o "$nvm_archive" \
    "https://github.com/nvm-sh/nvm/archive/refs/tags/v${PINNED_NVM_VERSION}.tar.gz"
  actual_nvm_sha256=$(shasum -a 256 "$nvm_archive" | awk '{ print $1 }')
  [ "$actual_nvm_sha256" = "$NVM_ARCHIVE_SHA256" ] ||
    fail "nvm archive SHA-256 mismatch"
  mkdir -p "$nvm_dir"
  tar -xzf "$nvm_archive" --strip-components=1 -C "$nvm_dir"
fi

# Keep these variables literal for evaluation by future interactive shells.
# shellcheck disable=SC2016
nvm_load='export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
append_line_once "$HOME/.zshrc" "$nvm_load"
append_line_once "$HOME/.zprofile" "$nvm_load"

export NVM_DIR="$nvm_dir"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"
[ "$(nvm --version)" = "$PINNED_NVM_VERSION" ] ||
  fail "installed nvm version differs from the reviewed version"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use "$NODE_VERSION"
npm install --global @openai/codex@latest

open -a UURemote || true

printf '\nPost-install completed.\n'
printf 'Outbound public key for the Ubuntu peer:\n'
cat "${outbound_key}.pub"
printf '\nVersions:\n'
printf 'nvm=%s\n' "$(nvm --version)"
printf 'node=%s\n' "$(node --version)"
printf 'npm=%s\n' "$(npm --version)"
printf 'codex=%s\n' "$(codex --version)"
printf '\nRemote services:\n'
sudo systemsetup -getremotelogin
pmset -g custom
printf '\nGrant UU Remote Accessibility and Screen Recording in System Settings.\n'
