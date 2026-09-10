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

# --- preflight: everything that can refuse, before anything that writes -------
#
# The order matters and it is the order bootstrap.sh already uses: check first,
# touch afterwards. ~/.dotfiles is the name every later step resolves through,
# and repointing it for a run that then refuses leaves the machine pointing at
# a configuration this script has just declared unusable - including the editor
# and terminal config home.nix reaches through that name, and the rollback
# commands HOW-TO.md gives.

# Home Manager's activation makes the same comparison and aborts on a
# mismatch, but only after a full build, and it cannot know that the answer
# lives on two editable lines in this repo. Checking here costs nothing and
# says what to do about it.
flake_settings_check_machine "$DIR/flake.nix"

# The switch below runs `nix`, and a terminal that was already open when Nix
# was installed does not have it - which is the normal state of the shell
# ./bootstrap.sh just finished in. bootstrap.sh guards its own switch for
# exactly this reason and says so in as many words; without the same guard
# here, that shell gets a bare `rebuild.sh: line NN: nix: command not found`
# and no hint that the fix is to open a new terminal.
#
# `|| true` keeps the lookup from aborting the script under set -euo pipefail,
# so the guard below is what reports a missing nix instead of a silent exit.
NIX_BIN="$(command -v nix || true)"
if [ -z "$NIX_BIN" ]; then
  echo "ERROR: nix is not on this shell's PATH, so the switch cannot run." >&2
  echo "       The Determinate installer only adds nix to the PATH of new" >&2
  echo "       shells, so a terminal that was already open when Nix was" >&2
  echo "       installed - the one ./bootstrap.sh ran in, most often - will" >&2
  echo "       never have it." >&2
  echo "       Open a new terminal and run ./rebuild.sh there." >&2
  exit 1
fi

CONFIG_NAME="$(flake_settings_config_name "$DIR/flake.nix")"

# --- from here on this run writes --------------------------------------------

# home.nix's editor and terminal config resolve through ~/.dotfiles, and the
# switch below builds ~/.dotfiles#<name>.
dotfiles_link_apply "$DIR"

# Not `exec`: the identity report below has to run after the switch, which is
# what installs home.nix's includes of ~/.gitconfig.local and ~/.gitconfig.work.
# The switch's own exit status is kept and re-raised, so a report can neither
# fail a good rebuild nor hide a failed one.
# `nix run ~/.dotfiles#home-manager` rather than a `home-manager` on PATH: it
# is the revision flake.lock pins, it is the same command bootstrap.sh runs on
# a machine that has no profile yet, and it cannot be shadowed by some other
# Home Manager the machine happens to carry.
STATUS=0
"$NIX_BIN" run "$HOME/.dotfiles#home-manager" -- switch --flake "$HOME/.dotfiles#$CONFIG_NAME" || STATUS=$?

# The last thing on the screen has to be the truth about the run.
#
# Keeping the exit status honest is not enough: an interactive shell does not
# show it. The identity report is friendly advice, and printing it after a
# failed switch put seven reassuring lines underneath an error - which is how a
# run that changed nothing comes to read like a run that worked.
if [ "$STATUS" = 0 ]; then
  git_identity_report
else
  echo "ERROR: the switch failed, so nothing in your home directory changed." >&2
  echo "       Nothing was installed, updated or removed by this run." >&2
  echo "       The error itself is above this line. HOW-TO.md's Troubleshooting" >&2
  echo "       section covers the ones that come up." >&2
fi

exit "$STATUS"
