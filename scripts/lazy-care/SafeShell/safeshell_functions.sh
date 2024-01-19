function saferm() {
    local base_path="/mnt/disk/BIN/ROOT"
    for arg in "$@"; do
        local abs_path=$(realpath "$arg")
        local target_dir="${base_path}$(dirname "$abs_path")"
        mkdir -p "$target_dir"
        mv "$abs_path" "$target_dir"
    done
}

alias rm='saferm'

function unrm() {
    local base_path="/mnt/disk/BIN/ROOT"
    for arg in "$@"; do
        local trash_path="${base_path}/${arg}"
        if [ -e "$trash_path" ]; then
            mv "$trash_path" "$(dirname "$arg")/"
        else
            echo "File not found in trash: $arg"
        fi
    done
}

alias unrm='unrm'

function removeitanyway() {
    local base_path="/mnt/disk/BIN/ROOT"
    echo "Warning: This will permanently delete the following items:"
    for arg in "$@"; do
        local abs_path=$(realpath "$arg" 2>/dev/null || echo "$arg")
        local trash_path="${base_path}${abs_path}"
        echo "Current location: $abs_path"
        echo "Trash location: $trash_path"
        echo "Consider using 'saferm' for a reversible operation."
    done

    read -p "Confirm permanent deletion? (yes/no) " confirmation
    if [ "$confirmation" = "yes" ]; then
        for arg in "$@"; do
            local abs_path=$(realpath "$arg" 2>/dev/null || echo "$arg")
            local trash_path="${base_path}${abs_path}"
            [ -e "$abs_path" ] && /bin/rm -rf "$abs_path"
            [ -e "$trash_path" ] && /bin/rm -rf "$trash_path"
        done
    else
        echo "Operation cancelled."
    fi
}

alias removeitanyway='removeitanyway'

