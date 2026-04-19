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

function claude_wipe {
    local claude_dir="$HOME/.claude"
    if [[ ! -d "$claude_dir" ]]; then
        echo "$claude_dir does not exist" >&2
        return 1
    fi

    # Pull --dry-run out of the arg list so it composes with any other mode.
    local dry_run=0
    local args=()
    local a
    for a in "$@"; do
        if [[ "$a" == "--dry-run" ]]; then
            dry_run=1
        else
            args+=("$a")
        fi
    done

    # --all / --with-memory: wipe every transient directory.
    # --with-memory also wipes per-project memory/ and downloads/.
    if [[ "${args[1]}" == "--all" || "${args[1]}" == "--with-memory" ]]; then
        local deep=0
        [[ "${args[1]}" == "--with-memory" ]] && deep=1
        if (( dry_run )); then
            echo "[dry-run] would shred Claude Code transient state under $claude_dir."
        else
            echo "About to shred Claude Code transient state under $claude_dir."
        fi
        if (( deep )); then
            echo "Including per-project memory/ and downloads/ (--with-memory)."
        else
            echo "Preserving per-project memory/ and downloads/ (pass --with-memory to also wipe)."
        fi
        echo "Keeps: .credentials.json, settings.json, plugins/."
        if (( ! dry_run )); then
            echo "If Claude Code is currently running, close it first for a clean wipe."
            printf "Type 'yes' to confirm: "
            local answer
            read -r answer
            [[ "$answer" == "yes" ]] || { echo "Aborted."; return 1; }
        fi

        # Wipe everything in each project dir except memory/ (unless --with-memory).
        if [[ -d "$claude_dir/projects" ]]; then
            local proj entry
            for proj in "$claude_dir"/projects/*(N/); do
                for entry in "$proj"/*(DN); do
                    if (( ! deep )) && [[ "${entry:t}" == "memory" ]]; then
                        continue
                    fi
                    if (( dry_run )); then
                        echo "[dry-run] $entry"
                    else
                        find "$entry" -type f -exec shred -u {} + 2>/dev/null
                        rm -rf "$entry" 2>/dev/null
                    fi
                done
            done
        fi

        local targets=(
            "$claude_dir/file-history"
            "$claude_dir/session-env"
            "$claude_dir/shell-snapshots"
            "$claude_dir/sessions"
            "$claude_dir/backups"
            "$claude_dir/cache"
            "$claude_dir/telemetry"
            "$claude_dir/history.jsonl"
        )
        (( deep )) && targets+=("$claude_dir/downloads")
        local t
        for t in "${targets[@]}"; do
            [[ -e "$t" ]] || continue
            if (( dry_run )); then
                echo "[dry-run] $t"
            else
                find "$t" -type f -exec shred -u {} + 2>/dev/null
                rm -rf "$t" 2>/dev/null
            fi
        done
        if (( dry_run )); then
            echo "(dry-run — nothing was modified)"
        else
            echo "Wiped Claude Code transient state."
        fi
        return 0
    fi

    # Single session: explicit id or most-recent by mtime.
    local session_id="${args[1]}"
    if [[ -z "$session_id" ]]; then
        session_id=$(find "$claude_dir/projects" -maxdepth 2 -name '*.jsonl' -printf '%T@ %f\n' 2>/dev/null \
            | sort -rn | head -1 | awk '{print $2}' | sed 's/\.jsonl$//')
        if [[ -z "$session_id" ]]; then
            echo "No recent session found under $claude_dir/projects." >&2
            return 1
        fi
        echo "Most recent session: $session_id"
    fi

    if [[ ! "$session_id" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]]; then
        echo "Not a valid session id (uuid expected): $session_id" >&2
        return 1
    fi

    # (N) makes each glob null-match if nothing is there, so missing paths
    # don't error out.
    local targets=(
        "$claude_dir"/projects/*/"${session_id}.jsonl"(N)
        "$claude_dir"/projects/*/"${session_id}"(N/)
        "$claude_dir/file-history/${session_id}"(N/)
        "$claude_dir/session-env/${session_id}"(N/)
    )
    if (( ${#targets[@]} == 0 )); then
        echo "No files found for session $session_id." >&2
        return 1
    fi
    if (( ! dry_run )); then
        echo "Note: if Claude Code is actively running this session, the transcript may be recreated mid-wipe." >&2
    fi
    local t
    for t in "${targets[@]}"; do
        if (( dry_run )); then
            echo "[dry-run] $t"
        else
            find "$t" -type f -exec shred -u {} + 2>/dev/null
            rm -rf "$t" 2>/dev/null
        fi
    done
    if (( dry_run )); then
        echo "(dry-run — ${#targets[@]} path(s) listed for session $session_id)"
    else
        echo "Wiped ${#targets[@]} path(s) for session $session_id."
    fi
}
