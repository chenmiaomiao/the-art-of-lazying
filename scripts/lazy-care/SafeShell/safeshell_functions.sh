#!/usr/bin/env bash
# shellcheck shell=bash

# SafeShell keeps the familiar `rm` spelling while moving items into a
# path-mirroring trash tree. Source this file from Bash; do not execute it.

_saferm_error() {
    printf '%s\n' "$*" >&2
}

_saferm_exists() {
    [[ -e "$1" || -L "$1" ]]
}

_saferm_abs_path() {
    realpath -m -s -- "$1"
}

_saferm_trash_root() {
    _saferm_abs_path "${SAFERM_TRASH_ROOT:-/mnt/disk/BIN/ROOT}"
}

_saferm_require_trash_root() {
    local root
    root=$(_saferm_trash_root) || return 1

    # The production trash lives on a separate mounted disk. Refuse to create
    # a look-alike directory on / if that disk is unavailable. Tests and
    # portable deployments may explicitly override SAFERM_TRASH_ROOT.
    if [[ -z ${SAFERM_TRASH_ROOT:-} ]]; then
        if ! command -v mountpoint >/dev/null 2>&1 || ! mountpoint -q /mnt/disk; then
            _saferm_error "saferm: /mnt/disk is not mounted; nothing was changed"
            return 1
        fi
    fi

    if ! mkdir -p -- "$root"; then
        _saferm_error "saferm: cannot create trash root: $root"
        return 1
    fi
    if [[ ! -d "$root" || ! -w "$root" ]]; then
        _saferm_error "saferm: trash root is not a writable directory: $root"
        return 1
    fi
}

_saferm_path_is_core_protected() {
    local path=$1
    local home_path
    home_path=$(_saferm_abs_path "${HOME:-/home/${USER:-lachlan}}") || return 0

    case "$path" in
        / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | \
        /libx32 | /lost+found | /media | /mnt | /opt | /proc | /root | /run | \
        /sbin | /snap | /srv | /sys | /tmp | /usr | /var | "$home_path")
            return 0
            ;;
    esac
    return 1
}

_saferm_path_is_protected_from_move() {
    local path=$1 root=$2
    _saferm_path_is_core_protected "$path" && return 0

    # Never move the trash, an item already in it, or one of its ancestors.
    [[ "$path" == "$root" || "$path" == "$root"/* || "$root" == "$path"/* ]]
}

_saferm_path_is_protected_from_permanent_delete() {
    local path=$1 root=$2
    local user_name=${USER:-lachlan}

    _saferm_path_is_core_protected "$path" && return 0
    [[ "$path" == "$root" || "$root" == "$path"/* ]] && return 0

    # Also guard the broad mirror roots inside the trash. Individual entries
    # below them remain removable after the explicit permanent-delete prompt.
    case "$path" in
        "$root"/bin | "$root"/boot | "$root"/dev | "$root"/etc | \
        "$root"/home | "$root"/home/"$user_name" | "$root"/lib | \
        "$root"/lib32 | "$root"/lib64 | "$root"/libx32 | "$root"/media | \
        "$root"/mnt | "$root"/opt | "$root"/proc | "$root"/root | \
        "$root"/run | "$root"/sbin | "$root"/snap | "$root"/srv | \
        "$root"/sys | "$root"/tmp | "$root"/usr | "$root"/var)
            return 0
            ;;
    esac
    return 1
}

# Parse the useful GNU rm options while keeping all path operands NUL-safe in
# a Bash array. Recursive flags are accepted but unnecessary for mv.
_saferm_parse_rm_options() {
    local paths_name=$1 force_name=$2 interactive_name=$3
    local verbose_name=$4 one_fs_name=$5 action_name=$6
    shift 6

    local -n parsed_paths=$paths_name
    local -n parsed_force=$force_name
    local -n parsed_interactive=$interactive_name
    local -n parsed_verbose=$verbose_name
    local -n parsed_one_fs=$one_fs_name
    local -n parsed_action=$action_name

    parsed_paths=()
    parsed_force=0
    parsed_interactive=never
    parsed_verbose=0
    parsed_one_fs=0
    parsed_action=run

    local parsing_options=1 arg cluster flag when
    while (($#)); do
        arg=$1
        shift

        if ((parsing_options)) && [[ "$arg" == -- ]]; then
            parsing_options=0
            continue
        fi

        if ((parsing_options)) && [[ "$arg" == --* ]]; then
            case "$arg" in
                --force)
                    parsed_force=1
                    parsed_interactive=never
                    ;;
                --interactive)
                    parsed_force=0
                    parsed_interactive=always
                    ;;
                --interactive=*)
                    when=${arg#*=}
                    case "$when" in
                        always | yes)
                            parsed_force=0
                            parsed_interactive=always
                            ;;
                        once)
                            parsed_force=0
                            parsed_interactive=once
                            ;;
                        never | no | none)
                            parsed_interactive=never
                            ;;
                        *)
                            _saferm_error "saferm: invalid --interactive value: $when"
                            return 2
                            ;;
                    esac
                    ;;
                --recursive | --dir | --preserve-root | --preserve-root=all)
                    ;;
                --one-file-system)
                    parsed_one_fs=1
                    ;;
                --verbose)
                    parsed_verbose=1
                    ;;
                --no-preserve-root)
                    _saferm_error "saferm: --no-preserve-root is intentionally unsupported"
                    return 2
                    ;;
                --help)
                    parsed_action=help
                    ;;
                --version)
                    parsed_action=version
                    ;;
                *)
                    _saferm_error "saferm: unsupported option: $arg (use -- before a dash-leading filename)"
                    return 2
                    ;;
            esac
            continue
        fi

        if ((parsing_options)) && [[ "$arg" == -?* && "$arg" != - ]]; then
            cluster=${arg#-}
            while [[ -n "$cluster" ]]; do
                flag=${cluster:0:1}
                cluster=${cluster:1}
                case "$flag" in
                    f)
                        parsed_force=1
                        parsed_interactive=never
                        ;;
                    i)
                        parsed_force=0
                        parsed_interactive=always
                        ;;
                    I)
                        parsed_force=0
                        parsed_interactive=once
                        ;;
                    r | R | d)
                        ;;
                    v)
                        parsed_verbose=1
                        ;;
                    *)
                        _saferm_error "saferm: unsupported option: -$flag (from $arg)"
                        return 2
                        ;;
                esac
            done
            continue
        fi

        parsed_paths+=("$arg")
    done
}

_saferm_confirm() {
    local prompt=$1 reply
    if [[ ! -t 0 ]]; then
        _saferm_error "saferm: confirmation requires an interactive terminal"
        return 1
    fi
    read -r -p "$prompt [y/N] " reply || return 1
    [[ "$reply" == y || "$reply" == Y || "$reply" == yes || "$reply" == YES ]]
}

_saferm_target_for() {
    local original=$1 root=$2
    local relative=${original#/}
    local target="$root/$relative"
    local stamp candidate counter=0
    local -a existing_versions=()

    # Reuse the plain mirrored name only when no older version exists. This
    # keeps the plain name as the oldest entry and timestamped names as newer
    # entries, even after somebody restores only one version.
    _saferm_collect_exact_matches "$original" "$root" existing_versions
    if ! _saferm_exists "$target" && ((${#existing_versions[@]} == 0)); then
        printf '%s\n' "$target"
        return 0
    fi

    stamp=$(date -u '+%Y%m%dT%H%M%S.%NZ') || return 1
    candidate="${target}.~saferm~${stamp}~$$"
    while _saferm_exists "$candidate"; do
        ((counter += 1))
        candidate="${target}.~saferm~${stamp}~$$~${counter}"
    done
    printf '%s\n' "$candidate"
}

_saferm_add_unique() {
    local array_name=$1 value=$2 existing
    local -n values=$array_name
    for existing in "${values[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    values+=("$value")
}

_saferm_original_from_trash() {
    local trash_path=$1 root=$2
    local relative parent name

    [[ "$trash_path" == "$root"/* ]] || return 1
    relative=${trash_path#"$root"/}
    parent=${relative%/*}
    name=${relative##*/}
    [[ "$parent" == "$relative" ]] && parent=

    # Current collision suffix.
    if [[ "$name" =~ ^(.*)\.~saferm~[0-9]{8}T[0-9]{6}\.[0-9]{9}Z~[0-9]+(~[0-9]+)?$ ]]; then
        name=${BASH_REMATCH[1]}
    # Legacy collision suffix used by the original helper.
    elif [[ "$name" =~ ^(.*)_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        name=${BASH_REMATCH[1]}
    fi

    if [[ -n "$parent" ]]; then
        printf '/%s/%s\n' "$parent" "$name"
    else
        printf '/%s\n' "$name"
    fi
}

_saferm_collect_exact_matches() {
    local original=$1 root=$2 output_name=$3
    local -n output=$output_name
    local target parent candidate candidate_original

    target="$root/${original#/}"
    parent=$(dirname -- "$target") || return 1
    [[ -d "$parent" ]] || return 0

    while IFS= read -r -d '' candidate; do
        candidate_original=$(_saferm_original_from_trash "$candidate" "$root") || continue
        if [[ "$candidate_original" == "$original" ]]; then
            _saferm_add_unique "$output_name" "$candidate"
        fi
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

_saferm_collect_name_matches() {
    local query=$1 root=$2 output_name=$3 search=$4
    local -n output=$output_name
    local candidate original

    while IFS= read -r -d '' candidate; do
        original=$(_saferm_original_from_trash "$candidate" "$root") || continue
        if ((search)); then
            [[ "$original" == *"$query"* ]] || continue
        else
            [[ "${original##*/}" == "$query" ]] || continue
        fi
        _saferm_add_unique "$output_name" "$candidate"
    done < <(find "$root" -mindepth 1 -print0 2>/dev/null)
}

_saferm_print_matches() {
    local array_name=$1 root=$2
    local -n _print_values=$array_name
    local i original
    for i in "${!_print_values[@]}"; do
        original=$(_saferm_original_from_trash "${_print_values[$i]}" "$root") || original='(unknown)'
        printf '  %d) trash: %q\n     original: %q\n' \
            "$((i + 1))" "${_print_values[$i]}" "$original"
    done
}

_saferm_choose_newest() {
    local array_name=$1 output_name=$2
    local -n _newest_values=$array_name
    local -n _newest_output=$output_name
    local candidate name rank score
    local best_rank=-1 best_score=

    _newest_output=
    for candidate in "${_newest_values[@]}"; do
        name=${candidate##*/}
        if [[ "$name" =~ \.~saferm~([0-9]{8}T[0-9]{6}\.[0-9]{9}Z~[0-9]+(~[0-9]+)?)$ ]]; then
            rank=2
            score=${BASH_REMATCH[1]}
        elif [[ "$name" =~ _([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})$ ]]; then
            rank=1
            score=${BASH_REMATCH[1]}
        else
            rank=0
            score=
        fi
        if ((rank > best_rank)) || { ((rank == best_rank)) && [[ "$score" > "$best_score" ]]; }; then
            best_rank=$rank
            best_score=$score
            _newest_output=$candidate
        fi
    done
    [[ -n "$_newest_output" ]]
}

_saferm_usage() {
    cat <<'EOF'
Usage: rm [RM_OPTIONS] [--] PATH...

SafeShell moves each PATH to /mnt/disk/BIN/ROOT/<absolute-path> instead of
deleting it. Common rm flags (-f, -r/-R, -d, -i/-I, -v and long forms) are
accepted. Use -- before a filename beginning with a dash.
EOF
}

_unrm_usage() {
    cat <<'EOF'
Usage: unrm [--list] [--newest] [--search] SOURCE [DESTINATION]
       unrm [--list] [--newest] [--search] SOURCE --to DESTINATION

SOURCE may be an original absolute/relative path, ./ or ../ path, a direct
/mnt/disk/BIN/ROOT/... path, or a bare filename. Existing destinations are
never overwritten. If DESTINATION is an existing directory, the restored item
is placed inside it.
EOF
}

_removeitanyway_usage() {
    cat <<'EOF'
Usage: removeitanyway [RM_OPTIONS] [--yes] [--] PATH...

Permanently removes each current PATH and every exact SafeShell trash version.
It prints the complete deletion plan and requires typing "yes". --yes is for
intentional non-interactive use; -f suppresses missing-path errors but never
bypasses confirmation.
EOF
}

saferm() {
    local -a paths=() items=()
    local force interactive verbose one_fs action
    local raw absolute root target parent status=0

    _saferm_parse_rm_options paths force interactive verbose one_fs action "$@" || return $?
    case "$action" in
        help)
            _saferm_usage
            return 0
            ;;
        version)
            printf 'SafeShell saferm 2.0\n'
            return 0
            ;;
    esac

    if ((${#paths[@]} == 0)); then
        ((force)) && return 0
        _saferm_error "saferm: missing operand"
        return 1
    fi

    root=$(_saferm_trash_root) || return 1
    for raw in "${paths[@]}"; do
        if [[ -z "$raw" ]]; then
            ((force)) || _saferm_error "saferm: cannot remove an empty path"
            ((force)) || status=1
            continue
        fi
        absolute=$(_saferm_abs_path "$raw") || {
            _saferm_error "saferm: cannot resolve path: $raw"
            status=1
            continue
        }
        if ! _saferm_exists "$absolute"; then
            ((force)) || _saferm_error "saferm: cannot remove '$raw': no such file or directory"
            ((force)) || status=1
            continue
        fi
        if _saferm_path_is_protected_from_move "$absolute" "$root"; then
            _saferm_error "saferm: refusing protected path: $absolute"
            status=1
            continue
        fi
        items+=("$absolute")
    done

    ((${#items[@]})) || return "$status"
    _saferm_require_trash_root || return 1

    if [[ "$interactive" == once ]]; then
        _saferm_confirm "Move ${#items[@]} item(s) to SafeShell trash?" || return 0
    fi

    for absolute in "${items[@]}"; do
        if [[ "$interactive" == always ]]; then
            _saferm_confirm "Move '$absolute' to SafeShell trash?" || continue
        fi

        target=$(_saferm_target_for "$absolute" "$root") || {
            _saferm_error "saferm: cannot allocate trash name for: $absolute"
            status=1
            continue
        }
        parent=$(dirname -- "$target") || {
            status=1
            continue
        }
        if ! mkdir -p -- "$parent"; then
            _saferm_error "saferm: cannot create trash parent: $parent"
            status=1
            continue
        fi
        if ! command mv -T -- "$absolute" "$target"; then
            _saferm_error "saferm: failed to move '$absolute' to '$target'"
            status=1
            continue
        fi
        ((verbose)) && printf "moved %q -> %q\n" "$absolute" "$target"
    done
    return "$status"
}

unrm() {
    local list=0 newest=0 search=0 parsing_options=1
    local destination= query= arg root query_absolute original selected parent reply
    local -a positionals=() matches=()

    while (($#)); do
        arg=$1
        shift
        if ((parsing_options)) && [[ "$arg" == -- ]]; then
            parsing_options=0
            continue
        fi
        if ((parsing_options)); then
            case "$arg" in
                --list)
                    list=1
                    continue
                    ;;
                --newest)
                    newest=1
                    continue
                    ;;
                --search)
                    search=1
                    continue
                    ;;
                --to)
                    if (($# == 0)); then
                        _saferm_error "unrm: --to requires a destination"
                        return 2
                    fi
                    destination=$1
                    shift
                    continue
                    ;;
                --help)
                    _unrm_usage
                    return 0
                    ;;
                -?*)
                    _saferm_error "unrm: unsupported option: $arg (use -- before a dash-leading path)"
                    return 2
                    ;;
            esac
        fi
        positionals+=("$arg")
    done

    if ((${#positionals[@]} == 0 || ${#positionals[@]} > 2)); then
        _unrm_usage >&2
        return 2
    fi
    query=${positionals[0]}
    if ((${#positionals[@]} == 2)); then
        if [[ -n "$destination" ]]; then
            _saferm_error "unrm: destination was specified twice"
            return 2
        fi
        destination=${positionals[1]}
    fi
    if [[ -z "$query" ]]; then
        _saferm_error "unrm: source path cannot be empty"
        return 2
    fi

    _saferm_require_trash_root || return 1
    root=$(_saferm_trash_root) || return 1
    query_absolute=$(_saferm_abs_path "$query") || return 1

    if [[ "$query_absolute" == "$root"/* ]]; then
        if _saferm_exists "$query_absolute"; then
            _saferm_add_unique matches "$query_absolute"
        else
            original=$(_saferm_original_from_trash "$query_absolute" "$root") || original=
            [[ -n "$original" ]] && _saferm_collect_exact_matches "$original" "$root" matches
        fi
    else
        _saferm_collect_exact_matches "$query_absolute" "$root" matches
    fi

    if ((${#matches[@]} == 0)) && { ((search)) || [[ "$query" != */* ]]; }; then
        _saferm_collect_name_matches "$query" "$root" matches "$search"
    fi

    if ((${#matches[@]} == 0)); then
        _saferm_error "unrm: no trash entry found for: $query"
        return 1
    fi

    if ((list)); then
        _saferm_print_matches matches "$root"
        return 0
    fi

    if ((${#matches[@]} == 1)); then
        selected=${matches[0]}
    elif ((newest)); then
        _saferm_choose_newest matches selected || return 1
    else
        _saferm_error "unrm: multiple versions match '$query':"
        _saferm_print_matches matches "$root" >&2
        if [[ ! -t 0 ]]; then
            _saferm_error "unrm: rerun with --newest, --list, or use an interactive terminal"
            return 2
        fi
        read -r -p "Select version [1-${#matches[@]}]: " reply || return 1
        if [[ ! "$reply" =~ ^[0-9]+$ ]] || ((reply < 1 || reply > ${#matches[@]})); then
            _saferm_error "unrm: invalid selection; nothing was changed"
            return 2
        fi
        selected=${matches[$((reply - 1))]}
    fi

    original=$(_saferm_original_from_trash "$selected" "$root") || {
        _saferm_error "unrm: cannot derive original path from: $selected"
        return 1
    }

    if [[ -z "$destination" ]]; then
        destination=$original
    else
        destination=$(_saferm_abs_path "$destination") || return 1
        if _saferm_exists "$destination" && [[ -d "$destination" && ! -L "$destination" ]]; then
            destination=${destination%/}/${original##*/}
        fi
    fi

    if [[ "$destination" == "$root" || "$destination" == "$root"/* ]]; then
        _saferm_error "unrm: destination must be outside the trash root: $destination"
        return 1
    fi
    if _saferm_exists "$destination"; then
        _saferm_error "unrm: refusing to overwrite existing destination: $destination"
        return 1
    fi

    parent=$(dirname -- "$destination") || return 1
    if ! mkdir -p -- "$parent"; then
        _saferm_error "unrm: cannot create destination parent: $parent"
        return 1
    fi
    if ! command mv -T -- "$selected" "$destination"; then
        _saferm_error "unrm: failed to restore '$selected' to '$destination'"
        return 1
    fi
    printf 'Restored %q -> %q\n' "$selected" "$destination"
}

removeitanyway() {
    local assume_yes=0 parsing_custom=1 arg
    local -a parser_args=() paths=() targets=() matches=() rm_args=(-rf)
    local force interactive verbose one_fs action root raw absolute target reply missing=0

    # --yes belongs to removeitanyway, not GNU rm. A literal file named --yes
    # remains addressable as `removeitanyway -- --yes`.
    for arg in "$@"; do
        if ((parsing_custom)) && [[ "$arg" == -- ]]; then
            parsing_custom=0
            parser_args+=("$arg")
        elif ((parsing_custom)) && [[ "$arg" == --yes ]]; then
            assume_yes=1
        else
            parser_args+=("$arg")
        fi
    done

    _saferm_parse_rm_options paths force interactive verbose one_fs action "${parser_args[@]}" || return $?
    case "$action" in
        help)
            _removeitanyway_usage
            return 0
            ;;
        version)
            printf 'SafeShell removeitanyway 2.0\n'
            return 0
            ;;
    esac
    if ((${#paths[@]} == 0)); then
        ((force)) && return 0
        _saferm_error "removeitanyway: missing operand"
        return 1
    fi

    _saferm_require_trash_root || return 1
    root=$(_saferm_trash_root) || return 1

    for raw in "${paths[@]}"; do
        matches=()
        if [[ -z "$raw" ]]; then
            ((force)) || _saferm_error "removeitanyway: empty path is invalid"
            ((force)) || missing=1
            continue
        fi
        absolute=$(_saferm_abs_path "$raw") || {
            missing=1
            continue
        }

        if [[ "$absolute" == "$root" || "$absolute" == "$root"/* ]]; then
            if _saferm_path_is_protected_from_permanent_delete "$absolute" "$root"; then
                _saferm_error "removeitanyway: refusing protected path: $absolute"
                missing=1
                continue
            fi
            if _saferm_exists "$absolute"; then
                _saferm_add_unique targets "$absolute"
            else
                ((force)) || _saferm_error "removeitanyway: no such trash entry: $raw"
                ((force)) || missing=1
            fi
            continue
        fi

        if _saferm_path_is_protected_from_permanent_delete "$absolute" "$root"; then
            _saferm_error "removeitanyway: refusing protected path: $absolute"
            missing=1
            continue
        fi
        _saferm_exists "$absolute" && _saferm_add_unique targets "$absolute"
        _saferm_collect_exact_matches "$absolute" "$root" matches
        for target in "${matches[@]}"; do
            _saferm_add_unique targets "$target"
        done
        if ! _saferm_exists "$absolute" && ((${#matches[@]} == 0)); then
            ((force)) || _saferm_error "removeitanyway: no current or trash entry found for: $raw"
            ((force)) || missing=1
        fi
    done

    if ((${#targets[@]} == 0)); then
        ((force && !missing)) && return 0
        return 1
    fi

    printf 'Permanent deletion plan (%d item(s)):\n' "${#targets[@]}"
    for target in "${targets[@]}"; do
        if [[ "$target" == "$root"/* ]]; then
            printf '  trash:   %q\n' "$target"
        else
            printf '  current: %q\n' "$target"
        fi
    done

    if ((!assume_yes)); then
        if [[ ! -t 0 ]]; then
            _saferm_error "removeitanyway: confirmation requires a terminal (or explicit --yes)"
            return 1
        fi
        read -r -p 'Type yes to permanently delete every listed item: ' reply || return 1
        if [[ "$reply" != yes ]]; then
            printf 'Nothing was deleted.\n'
            return 0
        fi
    fi

    ((one_fs)) && rm_args+=(--one-file-system)
    for target in "${targets[@]}"; do
        if ! /bin/rm "${rm_args[@]}" -- "$target"; then
            _saferm_error "removeitanyway: failed to delete: $target"
            missing=1
            continue
        fi
        printf 'Permanently removed %q\n' "$target"
    done
    return "$missing"
}

# Replace stale aliases from older revisions. `unrm` and `removeitanyway` are
# real functions; only rm needs an alias so ordinary shell usage stays simple.
unalias rm unrm removeitanyway 2>/dev/null || true
alias rm='saferm'
