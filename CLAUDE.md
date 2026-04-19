# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Personal dotfiles: a zsh config plus a small library of shell functions for workstation setup and encrypted secret management. There is no build, lint, or test tooling — changes are verified by re-sourcing and running the affected function.

## Layout

- `zsh/zshrc` — the file that `~/.zshrc` is symlinked to. At the bottom it sources `~/workspace/github.com/pooyarezaie/dotfiles/zsh/functions.sh` using an **absolute path**, so the repo must live at that location for the shell config to work.
- `zsh/functions.sh` — all user-defined shell functions. Sourced by `zshrc`.
- `zsh/secrets.env.example` — template of exported environment variables used by other functions. Copy to `secrets.env`, fill in, then encrypt to `secrets.age` with `age -p`.
- `zsh/secrets.age` — age-encrypted secrets file. Gitignored (`*.age` in `.gitignore`). Not checked in, despite existing locally.
- `kube/config.template` — kubeconfig with `${VAR}` placeholders. `kube_unlock` renders it into `$XDG_RUNTIME_DIR/kube/config` and exports `KUBECONFIG` for the current shell only.
- `DESIGN.md` — rationale for the security-relevant choices (threat model, why parse-don't-eval, why tmpfs, why template+envsubst instead of a symlinked kubeconfig). Read this before changing anything in `load_secrets` / `edit_secrets` / `kube_unlock`.

## How the pieces connect

- `functions.sh` sets `DOTFILES_DIR="${0:A:h:h}"` — the parent of the directory the script lives in. All functions that read repo-relative files (e.g. `secrets.age`, `kube/config.template`) go through this variable, so if you add new helpers that touch repo files, use `${DOTFILES_DIR}/...` rather than hardcoding paths.
- Secret lifecycle: plaintext `secrets.env` is never committed. `load_secrets` decrypts `secrets.age` and **parses** (does not `eval`) the `export KEY=VALUE` lines into the current shell, rejecting a denylist of shell/loader-hijacking vars (`PATH`, `LD_*`, `PROMPT_COMMAND`, etc.). `edit_secrets` decrypts to a temp file under `$XDG_RUNTIME_DIR` (tmpfs) with `chmod 600`, opens `$EDITOR`, re-encrypts with a passphrase on save, and **shreds every file in the tmpdir via a `trap ... EXIT HUP INT QUIT TERM`** — so any new edit helpers must preserve that trap signal list or they'll leak plaintext on terminal close / Ctrl-\.
- `export_claude` and `kube_unlock` both depend on variables populated by `load_secrets` — they check for them explicitly and error out with a clear message rather than silently running with empty values. Keep this pattern for any function that reads secret-sourced env vars.

## Testing changes

There is no test runner. To exercise a change:

```bash
source ~/workspace/github.com/pooyarezaie/dotfiles/zsh/functions.sh
<function_name>
```

Open a fresh zsh (`zsh -l`) to verify `zshrc` wiring end-to-end.

## External dependencies

- `age` — required for secrets (`apt install age`).
- `envsubst` (from `gettext-base`) — required by `kube_unlock` to render the kubeconfig template.
- `kubectl` with the `oidc-login` plugin (via `krew`) — the rendered kubeconfig uses it for OIDC authentication.
- Oh My Zsh with the `honukai` theme and `git` plugin — assumed installed at `$HOME/.oh-my-zsh`.
