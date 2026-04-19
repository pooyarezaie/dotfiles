#!/usr/bin/env zsh
# Dotfiles - shell functions for workstation setup and maintenance

DOTFILES_DIR="${0:A:h:h}"

function random_password {
    < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo;
}

function export_claude {
    if [[ -z "$CLAUDE_PROXY_IP" || -z "$CLAUDE_PROXY_PORT" ]]; then
        echo "CLAUDE_PROXY_IP and CLAUDE_PROXY_PORT not set. Run load_secrets first."
        return 1
    fi
    export HTTPS_PROXY="http://${CLAUDE_PROXY_IP}:${CLAUDE_PROXY_PORT}"
    export HTTP_PROXY="http://${CLAUDE_PROXY_IP}:${CLAUDE_PROXY_PORT}"
    echo "Proxy set to ${CLAUDE_PROXY_IP}:${CLAUDE_PROXY_PORT}"
}

function load_secrets {
    local secrets_file="${DOTFILES_DIR}/zsh/secrets.age"
    if [[ ! -f "$secrets_file" ]]; then
        echo "No secrets file found at ${secrets_file}"
        echo "See secrets.env.example to create one."
        return 1
    fi
    local decrypted
    decrypted=$(age -d "$secrets_file") || return 1

    # Parse KEY=VALUE lines instead of eval-ing — a tampered secrets.age
    # shouldn't be able to run arbitrary code. Supports optional leading
    # `export` and `#`-prefixed comments; rejects anything else.
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == export\ * ]] && line="${line#export }"
        if [[ "$line" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]]; then
            export "$line"
        else
            echo "load_secrets: skipping malformed line: $line" >&2
        fi
    done <<< "$decrypted"

    echo "Secrets loaded into current session."
}

function edit_secrets {
    local secrets_file="${DOTFILES_DIR}/zsh/secrets.age"
    # Tighten umask so the `age -d > $tmpfile` redirection creates the file
    # 0600 from the start, with no group/world-readable window before chmod.
    local old_umask
    old_umask=$(umask)
    umask 077
    # Prefer tmpfs ($XDG_RUNTIME_DIR) so plaintext never hits a journaling
    # filesystem where shred is unreliable. Fall back to the system default.
    local tmpbase="${XDG_RUNTIME_DIR:-}"
    if [[ -z "$tmpbase" || ! -w "$tmpbase" ]]; then
        tmpbase="${TMPDIR:-/tmp}"
    fi
    local tmpdir
    tmpdir=$(mktemp -d "${tmpbase}/edit_secrets.XXXXXX") || { umask "$old_umask"; return 1; }
    chmod 700 "$tmpdir"
    local tmpfile="${tmpdir}/secrets.env"

    # Shred every file in tmpdir on any exit — editors (vim .swp, emacs #file#,
    # backup ~ files, persistent undo) may write siblings next to $tmpfile.
    local cleanup="find '$tmpdir' -type f -exec shred -u {} + 2>/dev/null; rm -rf '$tmpdir' 2>/dev/null; umask '$old_umask'"
    trap "$cleanup" EXIT HUP INT QUIT TERM

    if [[ -f "$secrets_file" ]]; then
        age -d "$secrets_file" > "$tmpfile" || { trap - EXIT HUP INT QUIT TERM; eval "$cleanup"; return 1; }
    else
        touch "$tmpfile"
    fi
    chmod 600 "$tmpfile"

    local before after
    before=$(sha256sum "$tmpfile")
    case "${EDITOR:-vim}" in
        *vim|*vi)
            ${EDITOR:-vim} -n -i NONE \
                --cmd 'set nobackup nowritebackup noundofile noswapfile viminfo=' \
                "$tmpfile"
            ;;
        *)
            ${EDITOR:-vim} "$tmpfile"
            ;;
    esac
    after=$(sha256sum "$tmpfile")

    if [[ "$before" == "$after" ]]; then
        echo "No changes; secrets.age untouched."
    else
        age -p -o "${secrets_file}.new" "$tmpfile" && mv "${secrets_file}.new" "$secrets_file" \
            && echo "Secrets re-encrypted to ${secrets_file}." \
            || { echo "Encryption failed; original secrets.age kept."; rm -f "${secrets_file}.new"; }
    fi

    eval "$cleanup"
    trap - EXIT HUP INT QUIT TERM
}
