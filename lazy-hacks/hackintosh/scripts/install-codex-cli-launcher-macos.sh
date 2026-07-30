#!/bin/bash

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

readonly EXPECTED_PACKAGE="@openai/codex"
readonly LAUNCHER="$HOME/Applications/Codex CLI.command"
readonly DESKTOP_LINK="$HOME/Desktop/Codex CLI.command"
readonly REJECTED_LAUNCHER="$HOME/Applications/Codex Software Rendering.app"
readonly REJECTED_DESKTOP_LINK="$HOME/Desktop/Codex Software Rendering.app"
mode="${1:-install}"
codex_path=""
codex_version=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

write_launcher() {
  local destination="$1"

  cat > "$destination" <<'EOF'
#!/bin/zsh -l

exec codex
EOF
}

resolve_codex() {
  local node_path
  local node_bin_dir
  local npm_path
  local npm_root
  local package_json
  local package_name

  codex_path=$(
    /bin/zsh -lic 'command -v codex' 2>/dev/null |
      tail -n 1
  )
  [ -x "$codex_path" ] || fail "Codex CLI is not available in the login shell"
  case "$codex_path" in
    "$HOME"/.nvm/versions/node/*/bin/codex) ;;
    *) fail "Codex CLI is outside the reviewed per-user nvm tree: $codex_path" ;;
  esac

  node_bin_dir=$(dirname "$codex_path")
  node_path="$node_bin_dir/node"
  npm_path="$node_bin_dir/npm"
  [ -x "$node_path" ] || fail "the matching nvm Node binary is missing"
  [ -x "$npm_path" ] || fail "the matching nvm npm binary is missing"
  npm_root=$(PATH="$node_bin_dir:$PATH" "$npm_path" root -g)
  package_json="$npm_root/@openai/codex/package.json"
  [ -f "$package_json" ] || fail "$EXPECTED_PACKAGE is not installed"
  package_name=$(
    "$node_path" -e '
      const fs = require("fs");
      const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(metadata.name || "");
    ' "$package_json"
  )
  [ "$package_name" = "$EXPECTED_PACKAGE" ] ||
    fail "unexpected npm package at the Codex path: $package_name"

  codex_version=$(PATH="$node_bin_dir:$PATH" "$codex_path" --version)
  case "$codex_version" in
    "codex-cli "*) ;;
    *) fail "unexpected Codex version output: $codex_version" ;;
  esac
}

verify_launcher() {
  local expected

  [ -f "$LAUNCHER" ] || fail "$LAUNCHER is missing"
  [ -x "$LAUNCHER" ] || fail "$LAUNCHER is not executable"
  expected=$(mktemp "${TMPDIR:-/tmp}/codex-cli-launcher.XXXXXX")
  write_launcher "$expected"
  if ! cmp -s "$expected" "$LAUNCHER"; then
    rm -f "$expected"
    fail "$LAUNCHER has unexpected contents"
  fi
  rm -f "$expected"
  [ -L "$DESKTOP_LINK" ] || fail "$DESKTOP_LINK is missing"
  [ "$(readlink "$DESKTOP_LINK")" = "$LAUNCHER" ] ||
    fail "$DESKTOP_LINK points somewhere unexpected"
}

audit() {
  resolve_codex
  printf 'Codex CLI: %s\n' "$codex_version"
  printf 'Codex path: %s\n' "$codex_path"
  printf 'CLI launcher: '
  if [ -e "$LAUNCHER" ] || [ -L "$DESKTOP_LINK" ]; then
    verify_launcher
    printf 'installed and verified\n'
  else
    printf 'missing\n'
  fi
  printf 'Rejected Electron launcher: %s\n' \
    "$(
      if [ -e "$REJECTED_LAUNCHER" ] ||
        [ -L "$REJECTED_DESKTOP_LINK" ]; then
        printf present
      else
        printf absent
      fi
    )"
}

[ "$(uname -s)" = "Darwin" ] || fail "run this script on macOS"
[ "$(id -u)" -ne 0 ] || fail "run as the logged-in desktop user, not root"
case "$mode" in
  install|audit|uninstall) ;;
  *) fail "mode must be install, audit, or uninstall" ;;
esac

if [ "$mode" = "audit" ]; then
  audit
  exit 0
fi

if [ "$mode" = "uninstall" ]; then
  rm -f \
    "$DESKTOP_LINK" \
    "$LAUNCHER" \
    "$REJECTED_DESKTOP_LINK"
  rm -rf "$REJECTED_LAUNCHER"
  printf 'Removed Codex launchers created by this helper.\n'
  exit 0
fi

resolve_codex
mkdir -p "$HOME/Applications" "$HOME/Desktop"
stage=$(mktemp "${TMPDIR:-/tmp}/codex-cli-launcher.XXXXXX")
trap 'rm -f "$stage"' EXIT HUP INT TERM
write_launcher "$stage"
chmod 0755 "$stage"

rm -f "$DESKTOP_LINK" "$LAUNCHER" "$REJECTED_DESKTOP_LINK"
rm -rf "$REJECTED_LAUNCHER"
mv "$stage" "$LAUNCHER"
ln -s "$LAUNCHER" "$DESKTOP_LINK"
trap - EXIT HUP INT TERM

verify_launcher
printf 'Created: %s\n' "$LAUNCHER"
printf 'Shortcut: %s\n' "$DESKTOP_LINK"
printf 'Verified: %s (%s)\n' "$EXPECTED_PACKAGE" "$codex_version"
printf 'The rejected Electron software-rendering launcher was removed.\n'
