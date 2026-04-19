# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Personal dotfiles: a zsh config plus a small library of shell functions for workstation setup and encrypted secret management. There is no build, lint, or test tooling — changes are verified by re-sourcing and running the affected function.

## Layout

- `zsh/zshrc` — the file that `~/.zshrc` is symlinked to. At the bottom it sources `~/workspace/github.com/pooyarezaie/dotfiles/zsh/functions.sh` using an **absolute path**, so the repo must live at that location for the shell config to work.
- `zsh/functions.sh` — all user-defined shell functions. Sourced by `zshrc`.
- `zsh/secrets.env.example` — template of exported environment variables used by other functions. Copy to `secrets.env`, fill in, then encrypt to `secrets.age` with `age -p`.
- `zsh/secrets.age` — age-encrypted secrets file. Gitignored (`*.age` in `.gitignore`). Not checked in, despite existing locally.

## How the pieces connect

- `functions.sh` sets `DOTFILES_DIR="${0:A:h:h}"` — the parent of the directory the script lives in. All functions that read repo-relative files (e.g. `secrets.age`) go through this variable, so if you add new helpers that touch repo files, use `${DOTFILES_DIR}/...` rather than hardcoding paths.
- Secret lifecycle: plaintext `secrets.env` is never committed. `load_secrets` decrypts `secrets.age` in memory and `eval`s the `export` lines into the current shell. `edit_secrets` decrypts to a temp file under `mktemp -d` with `chmod 700`, opens `$EDITOR`, re-encrypts with a passphrase on save, and **shreds the plaintext via a `trap ... EXIT INT TERM`** — so any new edit helpers must preserve that trap discipline or they'll leak plaintext on Ctrl-C.
- `export_claude` depends on variables populated by `load_secrets` (`CLAUDE_PROXY_IP`, `CLAUDE_PROXY_PORT`). It errors out rather than silently running with empty values — keep this pattern for any function that reads secret-sourced env vars.

## Testing changes

There is no test runner. To exercise a change:

```bash
source ~/workspace/github.com/pooyarezaie/dotfiles/zsh/functions.sh
<function_name>
```

Open a fresh zsh (`zsh -l`) to verify `zshrc` wiring end-to-end.

## External dependencies

- `age` — required for secrets (`apt install age`).
- Oh My Zsh with the `honukai` theme and `git` plugin — assumed installed at `$HOME/.oh-my-zsh`.
