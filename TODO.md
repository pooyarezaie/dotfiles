# Security TODO

Remaining findings from the 2026-10 workstation audit, with reasons. The
firewall enable, vendored installers, kubectl checksum and v2ray config mode
are already handled by the setup playbook; everything below is not.

## Needs a decision / manual action

1. **Rotate the GitLab OAuth client secret** that sits in plaintext in
   `~/.gitconfig` under `[credential "https://git.divar.cloud"]`. Reason: the
   file was mode 755 and the secret must be treated as disclosed; rotation is
   the only fix. Afterwards keep the new one in a 0600 include:
   `git config --global include.path ~/.gitconfig-secret`.
2. **3x-ui container**: the firewall now blocks LAN access to it, but it still
   binds `*:2053/2096/10808/10809` with host networking and `restart=always`.
   Reason: defense shouldn't rest on the firewall alone — re-create it with
   bridge networking, port binds on `127.0.0.1` (or the NetBird IP), and
   `restart=unless-stopped`, so a future firewall change can't re-expose the
   panel/proxy on an untrusted network.
3. **File modes** (no sudo needed): `chmod 600 ~/.gitconfig ~/.ssh/config
   ~/.aws/cli/cache/session.db`. Reason: plaintext configs/tokens readable
   beyond the owner violate the tier-1 posture; the AWS CLI may recreate its
   cache with its own umask, so re-check it occasionally.

## Privileged checks

Results from 2026-10-15 in brackets where already run:

- [x] `lsblk -fs` — LUKS confirmed (`nvme0n1p3` crypto_LUKS, root on
  LVM-over-dm_crypt); tier-1 at-rest assumption holds.
- [x] `sudo aa-status` — 97 enforcing profiles; normal for a snap desktop.
- [x] `mokutil --sb-state; sysctl kernel.kptr_restrict
  kernel.unprivileged_bpf_disabled` — kernel values good (`1` / `2`), but
  **Secure Boot is disabled** — see below.
- [ ] `sudo usg audit cis_level2_workstation` — reason: usg is installed; this
  gives the full CIS report the spot-checks above only sample. (`cis_level1_
  workstation` is the lighter profile; `usg fix` exists but changes system
  state — read the audit report before fixing anything.)

## Additional finding from the privileged checks

- **Secure Boot disabled** (`mokutil --sb-state`). Reason to consider enabling:
  an unsigned bootloader/kernel can be modified by anything with disk write
  access (including the root-equivalent docker group), and kernel lockdown
  stays inactive. Trade-off: signing setup via MOK, and any out-of-tree
  kernel modules (VPN drivers etc.) would need enrolling. Decide deliberately
  rather than by default.

## Apt trust hygiene (sudo)

- Remove stale global anchors: `sudo rm /etc/apt/trusted.gpg.d/spotify*.gpg
  /etc/apt/trusted.gpg.d/ngrok.asc`. Reason: those repos are gone, and keys in
  `trusted.gpg.d` can vouch for **any** package source, not just their own.
- Move `warpdotdev.gpg` from `trusted.gpg.d` to `/etc/apt/keyrings/` and point
  `warpdotdev.list`'s `signed-by` at it. Reason: scoped trust — a vendor key
  should only answer for the vendor's repo.

## Code-level nits

- `export_claude` echoes the proxy address to the terminal. Reason: DESIGN.md
  says functions never print secret values; print "proxy set" instead.
- The vendored keys `setup/files/{chatgpt,netbird}.asc` are TOFU. Reason:
  verify once against vendor docs — NetBird `EFE3 7DF0 47DF 7CCD F1FC 54FA
  83F7 9AD0 2977 8355` (uid "Wiretrustee", their pre-rename name), ChatGPT
  `3BFA 0E4A E8B8 CC16 A2D9 BA68 4A3B 4A56 6C46 60E4` (uid "Codex Linux
  Repository") — and record the verification in a comment in the tasks files.
- AWS CLI zip and GCM .deb downloads are version-pinned but not checksummed.
  Reason: neither vendor publishes checksums for those artifacts; TLS-only
  TOFU is the accepted trade-off — revisit if hashes appear.
- Vendored installer scripts in `setup/files/` are pinned at vendor time.
  Reason: that is the point (no unpinned `curl | bash`), but refresh them
  deliberately when updating the tools they install.
- Legacy RSA-2048 `~/.ssh/id_rsa` alongside the FIDO2 `id_ed25519_sk`.
  Reason: old key type widens attack surface; retire once nothing depends on it.
- `kvm` group membership. Reason: `/dev/kvm` access widens kernel attack
  surface; drop it if no non-root VMs/emulators are used.
- `gnome-remote-desktop.service` runs with RDP disabled and no credentials.
  Reason: unused listener surface; disable the unit if never planned.
