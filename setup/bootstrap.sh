#!/usr/bin/env bash
# Installs Ansible and runs the workstation setup playbook.
#
# Usage (after cloning the repo to ~/workspace/github.com/pooyarezaie/dotfiles):
#   ./setup/bootstrap.sh                       # full setup
#   ./setup/bootstrap.sh --tags containers     # one category
#   ./setup/bootstrap.sh --check --diff        # dry run
#
# Extra arguments are passed straight to ansible-playbook.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "bootstrap.sh: run as your normal user, not root" >&2
    exit 1
fi

sudo apt update
sudo apt install -y ansible-core

cd "$(dirname "$0")/.."
exec ansible-playbook setup/playbook.yml --ask-become-pass "$@"
