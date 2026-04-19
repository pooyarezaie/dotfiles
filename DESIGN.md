# Design decisions

Why the secrets/kubeconfig workflow looks the way it does, and what was
considered and rejected. Short, opinionated notes — not a tutorial.

## Threat model

Two tiers, in descending order of importance:

1. **Offline filesystem access** — stolen disk, backup tape, shared mount
   image, a synced-to-the-cloud home directory. Secrets must be encrypted
   at rest.
2. **User-level malware** — code running as me on a live machine. It can
   read `/proc/<pid>/environ`, connect to sockets I own, dump my keyring,
   and request cached OIDC tokens. The only real defenses are (a)
   short-lived credentials (OIDC, cloud IAM) and (b) hardware tokens
   (YubiKey). Software-only schemes do not beat this threat.

The design targets tier 1 rigorously and accepts tier 2 as a documented
limitation. If tier 2 ever matters, the answer is a YubiKey / hardware
token, not more shell hardening.

## Secrets are one encrypted env file, not a keyring

`zsh/secrets.age` is an `age -p` passphrase-encrypted blob of
`export KEY=VALUE` lines. One file, one passphrase, decrypted on demand
by `load_secrets` for the current shell only. Chosen over:

- **OS keyring (libsecret / secret-tool)** — unlocked by the login
  password and session-wide. Any process in my D-Bus session reads it.
  Doesn't match "entered per terminal session" semantics, and no better
  than a plaintext file against tier-2 attackers.
- **`sops` (age backend)** — functionally equivalent and more powerful
  (partial-field encryption, multiple recipients, key rotation, diff
  filters). Bigger dependency, different threat model (key file on disk,
  no passphrase prompt by default). Kept as a future migration target —
  the shell functions can swap `age -d` for `sops -d` with few changes.
- **`chezmoi`** — whole dotfiles manager; too much scope for a personal
  repo that already works as plain symlinks.
- **`pass`** — per-secret files, different mental model. Doesn't solve
  the "load a bunch of env vars at once" problem as naturally.

## `load_secrets`: parse, don't `eval`

Earlier versions `eval`-ed the decrypted content. A tampered `secrets.age`
would then run arbitrary code at shell startup. The parser now reads one
line at a time, accepts `[A-Za-z_][A-Za-z0-9_]*=` with optional leading
`export`, strips trailing `\r` (for files ever edited on Windows/WSL),
and rejects everything else.

It also refuses a denylist of environment variables that could hijack the
shell or loader even when well-formed: `PATH`, `LD_*`, `DYLD_*`, `IFS`,
`PROMPT_COMMAND`, `PS0..PS4`, `BASH_ENV`, `ENV`, `ZDOTDIR`, `PYTHONPATH`,
`PERL5OPT`, `RUBYLIB`, `NODE_*`, `SHELL`, `HOME`, `USER`, `CDPATH`,
`FPATH`. Denylist over allowlist: the set of "user-supplied token-like
vars" grows (every new tool adds its own `*_TOKEN`), while the set of
"vars that can hijack the shell" is roughly fixed.

## `edit_secrets`: don't leave plaintext anywhere

- The decrypt → edit → re-encrypt temp file lives under
  `$XDG_RUNTIME_DIR` (tmpfs). `/tmp` on most Linux systems is a
  journaling filesystem where `shred` is unreliable; tmpfs disappears
  on unmount/reboot and never hits persistent storage.
- Cleanup shreds **every** file in the tmpdir, not just the single
  plaintext file, because editors drop siblings (`*.swp`, `*.un~`,
  `*~`, etc.). The vim/vi branch also passes
  `-n -i NONE --cmd 'set nobackup nowritebackup noundofile noswapfile viminfo='`
  so vim doesn't write those siblings in the first place.
- Cleanup is bound to `EXIT HUP INT QUIT TERM`. The short list `EXIT
  INT TERM` would miss terminal close (`SIGHUP`) and `Ctrl-\` (`SIGQUIT`).
- `umask 077` is set at function entry and restored via the cleanup so
  the `age -d > "$tmpfile"` redirection never creates the file
  world-readable before `chmod 600` catches up.
- The re-encrypt writes to `secrets.age.new` and atomically `mv`s it
  over `secrets.age` only on success — a failed encryption can't truncate
  the original.

## `kube_unlock`: template + envsubst + per-shell `KUBECONFIG`

The repo holds `kube/config.template` (committed) with placeholders for
everything sensitive: server URLs, CA data, OIDC client IDs, OIDC client
secrets, and the token-cache-dir. `kube_unlock` renders it with
`envsubst` using an explicit variable whitelist (so `$foo` inside a
secret value doesn't get re-interpreted) into
`$XDG_RUNTIME_DIR/kube/config` and exports `KUBECONFIG` for the current
shell. The kubelogin token cache is pinned to
`$XDG_RUNTIME_DIR/kube/oidc-cache` so the short-lived OIDC refresh/access
tokens share the same tmpfs/session lifetime.

Why this shape:

- **kubectl doesn't expand `$VAR` in YAML fields.** A symlink from
  `~/.kube/config` → a committed file with `${KUBE_API_SERVER}`
  placeholders would simply fail to parse. Render step is unavoidable.
- **Per-shell, not per-user.** The rendered file is at a path only the
  current shell knows via `$KUBECONFIG`; a terminal that never unlocks
  has no kubectl access. Matches the "just like ssh passphrase"
  requirement.
- **Kubelogin was already in use**, which is option "short-lived cloud
  tokens" from the threat-model hierarchy — the strongest tier below
  hardware tokens. The long-lived things that actually need protection
  are the OIDC client IDs and client secrets, not a static bearer
  token. The design reflects that: those are what's templated out.

## Non-goals / explicit limitations

- **Not defending against user-level malware.** Once code runs as me, it
  reads `/proc/<shell>/environ`, the rendered kubeconfig, and the OIDC
  token cache. Upgrade path: YubiKey-based client certs or hardware
  OIDC, not more shell plumbing.
- **No session-scoped agent daemon.** Considered and rejected — the
  ssh-agent-style design would reduce `/proc/environ` exposure slightly
  but keeps the same "same-user = access" boundary. Not worth the
  complexity on a single-user laptop.
- **Shell history hygiene is on the user.** `echo $SOMETOKEN` into a
  terminal with `HISTFILE` set still writes the secret to `.zsh_history`.
  The functions themselves never print secret values.
- **Backward compatibility** across these changes is not preserved — this
  is a personal repo, and each commit is allowed to break the previous
  workflow.
