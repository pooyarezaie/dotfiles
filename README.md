# Dotfiles

Personal tools for setting up and maintaining a secure workstation.

## Fresh machine

Clone the repo to the exact path `zsh/zshrc` hardcodes, then run the bootstrap script:

```bash
git clone https://github.com/pooyarezaie/dotfiles.git ~/workspace/github.com/pooyarezaie/dotfiles
cd ~/workspace/github.com/pooyarezaie/dotfiles
./setup/bootstrap.sh
```

`bootstrap.sh` installs Ansible and runs the playbook in [`setup/`](setup/), which installs everything: apps (official apt repos, snaps, and release binaries), the shell environment (Oh My Zsh with the honukai theme and plugins, nvm with Node LTS, pnpm), and the `~/.zshrc` / `~/.vimrc` symlinks. It is idempotent — re-running converges without changes. Categories can be run individually:

```bash
./setup/bootstrap.sh --tags containers   # browsers ai containers devcli security desktop shell
./setup/bootstrap.sh --check --diff      # dry run
```

Secrets are deliberately not automated; see [Secrets Management](#secrets-management) below and [`DESIGN.md`](DESIGN.md).

### After a fresh install

- Log out and back in (group memberships, zsh login shell).
- Restore `~/.ssh` from backup.
- Restore `zsh/secrets.age` from backup and run `load_secrets`.
- Restore `/usr/local/etc/v2ray/config.json` (contains server credentials; the v2ray service is left disabled).
- App logins: Chrome, ChatGPT, Spotify, VS Code (settings sync), `ngrok config add-authtoken`, `netbird up`.
- Cluster access: `load_secrets && kube_unlock`.
- Password safe: restore the `.psafe3` file and run `rclone config`.
- Optional: `sudo pro attach`; switch origin to SSH now that keys exist (`git remote set-url origin git@github.com:pooyarezaie/dotfiles.git`).

## Functions

### `random_password [length]`

Generates a random password using `/dev/urandom`. Default length is 32 characters. Characters include uppercase, lowercase, digits, and underscores.

```bash
random_password      # 32 characters
random_password 64   # 64 characters
```

### `load_secrets`

Decrypts `zsh/secrets.age` and exports the variables into the current shell session. Prompts for your age password each time.

```bash
load_secrets
```

### `edit_secrets`

Decrypts `zsh/secrets.age` into a temp file, opens it in `$EDITOR` (defaults to `vim`), and re-encrypts with a passphrase on close. The plaintext temp file is shredded on exit, even if the editor is interrupted. Skips re-encryption if the contents are unchanged.

```bash
edit_secrets
```

### `export_claude`

Sets `HTTP_PROXY` and `HTTPS_PROXY` using `CLAUDE_PROXY_IP` and `CLAUDE_PROXY_PORT` from secrets. Requires `load_secrets` to be run first.

```bash
load_secrets      # enter password
export_claude     # proxy is now active
```

### `kube_unlock`

Renders `kube/config.template` into `$XDG_RUNTIME_DIR/kube/config` (tmpfs, 0600) by substituting the `KUBE_*` and `OIDC_*` env vars, then exports `KUBECONFIG` so `kubectl` uses the rendered file in this shell only. `kubelogin`'s short-lived OIDC token cache is pinned to `$XDG_RUNTIME_DIR/kube/oidc-cache` (also tmpfs) via `--token-cache-dir`, so refresh/access tokens share the same per-session lifetime. Requires `load_secrets` first and `envsubst` (from `gettext-base`).

```bash
load_secrets      # enter passphrase
kube_unlock       # kubectl now works in this terminal
kubectl get pods
```

Another terminal running kubectl won't have `KUBECONFIG` set and will fall through to whatever (if anything) is at `~/.kube/config`.

See [`DESIGN.md`](DESIGN.md) for why the workflow is structured this way and what alternatives were considered.

### `claude_wipe`

Shreds Claude Code's local state under `~/.claude` (conversation transcripts, per-session file history, session env state, etc.) while keeping `.credentials.json`, `settings.json`, and `plugins/`. Useful after a session in which secrets were pasted or read into Claude's context.

```bash
claude_wipe                  # wipes the most recent session
claude_wipe <session-uuid>   # wipes a specific session
claude_wipe --all            # wipes everything transient (prompts to confirm)
claude_wipe --with-memory    # --all plus per-project memory/ and downloads/
claude_wipe --all --dry-run  # list what would be shredded; modifies nothing
```

Per-project `memory/` and `downloads/` are preserved by default on `--all` because they're deliberate long-term state (curated memory, files you explicitly fetched), not session spillover. Pass `--with-memory` to wipe them too.

`--dry-run` composes with any mode (bare, `<sid>`, `--all`, `--with-memory`) and prints the targets without touching anything.

If Claude Code is actively running, the transcript file can be recreated mid-wipe; the function prints a reminder. Close Claude first for a clean sweep.

## Secrets Management

Secrets are stored encrypted with `age` and are never committed to the repository.

### Initial setup

```bash
cd dotfiles/zsh
cp secrets.env.example secrets.env
```

Edit `secrets.env` with your actual values, then encrypt and delete the plaintext:

```bash
age -p -o secrets.age secrets.env
rm secrets.env
```

### Updating secrets

Use `edit_secrets` — it handles decryption, editing, re-encryption, and secure cleanup in one step.

### Format

`secrets.env` should contain one `export` statement per line:

```bash
export MY_TOKEN=value
export ANOTHER_SECRET=value
```

See `secrets.env.example` for the full list of expected variables.
