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
    local line key
    while IFS= read -r line; do
        # Strip CRLF trailer so CRLF-edited files (Windows/WSL) don't
        # smuggle a literal \r into the value.
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == export\ * ]] && line="${line#export }"
        if [[ ! "$line" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]]; then
            echo "load_secrets: skipping malformed line: $line" >&2
            continue
        fi
        key="${line%%=*}"
        # Refuse env vars that can hijack the shell or loader — a tampered
        # secrets.age must not be able to redirect PATH, preload libs, or
        # inject code via prompt/shell-init hooks.
        case "$key" in
            PATH|IFS|SHELL|HOME|USER|CDPATH|FPATH|ENV|BASH_ENV|ZDOTDIR|\
            PROMPT_COMMAND|PS0|PS1|PS2|PS3|PS4|\
            LD_*|DYLD_*|PERL5OPT|PYTHONPATH|RUBYLIB|NODE_OPTIONS|NODE_PATH)
                echo "load_secrets: refusing to set sensitive var: $key" >&2
                continue
                ;;
        esac
        export "$line"
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

function kube_unlock {
    local template="${DOTFILES_DIR}/kube/config.template"
    if [[ ! -f "$template" ]]; then
        echo "No kube template at $template" >&2
        return 1
    fi
    if ! command -v envsubst >/dev/null; then
        echo "envsubst not installed (apt install gettext-base)" >&2
        return 1
    fi

    local required=(
        KUBE_SERVER_HWB KUBE_SERVER_NEDA
        KUBE_CA_DATA_HWB KUBE_CA_DATA_NEDA
        OIDC_ISSUER_URL
        OIDC_CLIENT_ID_HWB OIDC_CLIENT_ID_NEDA
        OIDC_CLIENT_SECRET_HWB OIDC_CLIENT_SECRET_NEDA
    )
    local var missing=()
    for var in "${required[@]}"; do
        [[ -z "${(P)var}" ]] && missing+=("$var")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "kube_unlock: missing env vars (run load_secrets first): ${missing[*]}" >&2
        return 1
    fi

    # Render to tmpfs so the decrypted kubeconfig never touches spinning disk
    # and disappears on reboot. The oidc-login token cache goes alongside
    # it so cached OIDC tokens share the same lifetime.
    local outdir="${XDG_RUNTIME_DIR:-/tmp}/kube"
    local oidc_cache="${outdir}/oidc-cache"
    mkdir -p "$oidc_cache" && chmod 700 "$outdir" "$oidc_cache" || return 1
    local outfile="${outdir}/config"

    local old_umask
    old_umask=$(umask)
    umask 077
    # Restrict substitution to the listed vars so no stray $FOO inside a
    # secret value gets interpreted.
    KUBE_OIDC_CACHE_DIR="$oidc_cache" envsubst \
        '${KUBE_SERVER_HWB} ${KUBE_SERVER_NEDA}
         ${KUBE_CA_DATA_HWB} ${KUBE_CA_DATA_NEDA}
         ${OIDC_ISSUER_URL}
         ${OIDC_CLIENT_ID_HWB} ${OIDC_CLIENT_ID_NEDA}
         ${OIDC_CLIENT_SECRET_HWB} ${OIDC_CLIENT_SECRET_NEDA}
         ${KUBE_OIDC_CACHE_DIR}' \
        < "$template" > "$outfile" || { umask "$old_umask"; return 1; }
    umask "$old_umask"

    export KUBECONFIG="$outfile"
    echo "kubectl config rendered to $outfile; KUBECONFIG set for this session."
}
