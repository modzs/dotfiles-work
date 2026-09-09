#!/usr/bin/env bash
# Apply this configuration to your home directory.
#
# No sudo. Nothing outside $HOME is written, and nothing here can ask for a
# privilege it does not have. See README.md for what that means and AGENTS.md
# for why it is the whole point of this repo.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/dotfiles-link.sh
. "$DIR/lib/dotfiles-link.sh"
# shellcheck source=lib/flake-settings.sh
. "$DIR/lib/flake-settings.sh"
# shellcheck source=lib/git-identity.sh
. "$DIR/lib/git-identity.sh"

# Refuse before building, not after: home.nix's editor and terminal config
# resolve through ~/.dotfiles, and the switch below builds ~/.dotfiles#<name>.
dotfiles_link_apply "$DIR"

# Home Manager's activation makes the same comparison and aborts on a
# mismatch, but only after a full build, and it cannot know that the answer
# lives on two editable lines in this repo. Checking here costs nothing and
# says what to do about it.
flake_settings_check_machine "$DIR/flake.nix"

CONFIG_NAME="$(flake_settings_config_name "$DIR/flake.nix")"

# Not `exec`: the identity report below has to run after the switch, which is
# what installs home.nix's includes of ~/.gitconfig.local and ~/.gitconfig.work.
# The switch's own exit status is kept and re-raised, so a report can neither
# fail a good rebuild nor hide a failed one.
# `nix run ~/.dotfiles#home-manager` rather than a `home-manager` on PATH: it
# is the revision flake.lock pins, it is the same command bootstrap.sh runs on
# a machine that has no profile yet, and it cannot be shadowed by some other
# Home Manager the machine happens to carry.
STATUS=0
nix run "$HOME/.dotfiles#home-manager" -- switch --flake "$HOME/.dotfiles#$CONFIG_NAME" || STATUS=$?

git_identity_report

exit "$STATUS"
