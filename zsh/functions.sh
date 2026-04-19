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
    eval "$decrypted"
    echo "Secrets loaded into current session."
}

function edit_secrets {
    local secrets_file="${DOTFILES_DIR}/zsh/secrets.age"
    local tmpdir
    tmpdir=$(mktemp -d) || return 1
    chmod 700 "$tmpdir"
    local tmpfile="${tmpdir}/secrets.env"

    # Shred plaintext on any exit path (success, error, or interrupt).
    trap "shred -u '$tmpfile' 2>/dev/null; rmdir '$tmpdir' 2>/dev/null" EXIT INT TERM

    if [[ -f "$secrets_file" ]]; then
        age -d "$secrets_file" > "$tmpfile" || { trap - EXIT INT TERM; shred -u "$tmpfile" 2>/dev/null; rmdir "$tmpdir"; return 1; }
    else
        touch "$tmpfile"
    fi
    chmod 600 "$tmpfile"

    local before after
    before=$(sha256sum "$tmpfile")
    ${EDITOR:-vim} "$tmpfile"
    after=$(sha256sum "$tmpfile")

    if [[ "$before" == "$after" ]]; then
        echo "No changes; secrets.age untouched."
    else
        age -p -o "${secrets_file}.new" "$tmpfile" && mv "${secrets_file}.new" "$secrets_file" \
            && echo "Secrets re-encrypted to ${secrets_file}." \
            || { echo "Encryption failed; original secrets.age kept."; rm -f "${secrets_file}.new"; }
    fi

    shred -u "$tmpfile" 2>/dev/null
    rmdir "$tmpdir" 2>/dev/null
    trap - EXIT INT TERM
}
