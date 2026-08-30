#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
sandbox=$(mktemp -d -t safeshell-test.XXXXXXXX)
trap '/bin/rm -rf -- "$sandbox"' EXIT

export SAFERM_TRASH_ROOT="$sandbox/trash/ROOT"
# shellcheck source=safeshell_functions.sh
source "$script_dir/safeshell_functions.sh"
shopt -s expand_aliases

workspace="$sandbox/work area"
mkdir -p -- "$workspace/sub"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_exists() {
    _saferm_exists "$1" || fail "expected path to exist: $1"
}

assert_absent() {
    ! _saferm_exists "$1" || fail "expected path to be absent: $1"
}

# Common rm options and paths containing spaces.
mkdir -p -- "$workspace/dir with spaces/nested"
touch -- "$workspace/dir with spaces/nested/file"
saferm -rf "$workspace/dir with spaces"
assert_absent "$workspace/dir with spaces"
assert_exists "$SAFERM_TRASH_ROOT/${workspace#/}/dir with spaces"
(
    cd -- "$workspace"
    unrm './dir with spaces'
)
assert_exists "$workspace/dir with spaces/nested/file"

# Absolute-path restore.
touch -- "$workspace/absolute.txt"
saferm "$workspace/absolute.txt"
unrm "$workspace/absolute.txt"
assert_exists "$workspace/absolute.txt"

# The public `rm` alias expands to the same implementation in an interactive
# Bash parse. eval gives this non-interactive test a fresh alias-expansion pass.
touch -- "$workspace/alias.txt"
eval 'rm -f -- "$workspace/alias.txt"'
assert_absent "$workspace/alias.txt"
unrm "$workspace/alias.txt"
assert_exists "$workspace/alias.txt"

# ../ path restore.
touch -- "$workspace/relative.txt"
(
    cd -- "$workspace/sub"
    saferm ../relative.txt
    unrm ../relative.txt
)
assert_exists "$workspace/relative.txt"

# A dash-leading filename must work after --.
(
    cd -- "$workspace"
    touch -- -leading-name
    saferm -f -- -leading-name
    assert_absent "$workspace/-leading-name"
    unrm -- ./-leading-name
)
assert_exists "$workspace/-leading-name"

# Dangling symlinks are moved and restored as links, not dereferenced.
ln -s -- missing-target "$workspace/dangling-link"
saferm "$workspace/dangling-link"
assert_absent "$workspace/dangling-link"
unrm "$workspace/dangling-link"
[[ -L "$workspace/dangling-link" ]] || fail 'dangling symlink was not restored as a symlink'
[[ "$(readlink -- "$workspace/dangling-link")" == missing-target ]] || fail 'symlink target changed'

# A direct trash path restores to an explicit destination without adding a
# second trash-root prefix.
touch -- "$workspace/direct.txt"
saferm "$workspace/direct.txt"
direct_trash="$SAFERM_TRASH_ROOT/${workspace#/}/direct.txt"
assert_exists "$direct_trash"
unrm "$direct_trash" --to "$workspace/direct-restored.txt"
assert_absent "$direct_trash"
assert_exists "$workspace/direct-restored.txt"

# Existing destination-directory semantics.
mkdir -p -- "$workspace/destination"
touch -- "$workspace/to-directory.txt"
saferm "$workspace/to-directory.txt"
unrm "$workspace/to-directory.txt" "$workspace/destination"
assert_exists "$workspace/destination/to-directory.txt"

# Bare-name lookup and the legacy timestamp suffix remain compatible.
touch -- "$workspace/bare-only.txt"
saferm "$workspace/bare-only.txt"
(
    cd -- "$workspace/sub"
    unrm bare-only.txt
)
assert_exists "$workspace/bare-only.txt"

legacy_original="$workspace/legacy.txt"
legacy_trash="$SAFERM_TRASH_ROOT/${legacy_original#/}_2024-05-06_07-08-09"
mkdir -p -- "$(dirname -- "$legacy_trash")"
touch -- "$legacy_trash"
unrm "$legacy_original"
assert_exists "$legacy_original"

# Repeated removals preserve versions; --newest restores the latest one and
# removeitanyway removes the current copy plus every exact trash version.
printf 'first\n' >"$workspace/versioned.txt"
saferm "$workspace/versioned.txt"
printf 'second\n' >"$workspace/versioned.txt"
saferm "$workspace/versioned.txt"
version_count=$(unrm --list "$workspace/versioned.txt" | grep -c 'trash:')
[[ "$version_count" == 2 ]] || fail "expected two trash versions, found $version_count"
unrm --newest "$workspace/versioned.txt"
grep -qx 'second' "$workspace/versioned.txt" || fail 'newest version was not restored'
removeitanyway --yes -rf "$workspace/versioned.txt"
assert_absent "$workspace/versioned.txt"
if unrm --list "$workspace/versioned.txt" >/dev/null 2>&1; then
    fail 'versioned entry remained after removeitanyway'
fi

# -f ignores missing paths, and broad roots remain protected.
saferm -f "$workspace/does-not-exist"
if saferm "$sandbox" >/dev/null 2>&1; then
    fail 'saferm accepted an ancestor of its trash root'
fi
if removeitanyway --yes "$SAFERM_TRASH_ROOT" >/dev/null 2>&1; then
    fail 'removeitanyway accepted the trash root'
fi

printf 'SafeShell tests passed in %s\n' "$sandbox"
