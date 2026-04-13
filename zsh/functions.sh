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
