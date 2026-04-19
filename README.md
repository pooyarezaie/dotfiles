# Dotfiles

Personal tools for setting up and maintaining a secure workstation.

## Setup

1. Symlink `~/.zshrc` to the version-controlled copy:

   ```bash
   ln -sf ~/workspace/github.com/pooyarezaie/dotfiles/zsh/zshrc ~/.zshrc
   ```

2. Install [age](https://github.com/FiloSottile/age) for secret management:

   ```bash
   sudo apt install age
   ```

3. Set up your encrypted secrets (see [Secrets Management](#secrets-management) below).

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
