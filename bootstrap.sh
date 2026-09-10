#!/usr/bin/env bash
# Bootstrap from nothing to a configured home directory on macOS.
# Run this once. After it finishes, use ./rebuild.sh for every later change.
#
# The only thing here that needs sudo is the Nix installer in step 1, and that
# is the only time this repo asks for a password. No machine name, no /etc, no
# macOS system settings, and no package manager installed on your behalf.
#
# One part of the switch in step 6 does reach outside your home directory: it
# hands a generated Brewfile to a Homebrew you installed yourself, and Homebrew
# installs into its own prefix. It uninstalls nothing, and it neither installs
# nor updates Homebrew itself. The one thing it will replace is an application
# already sitting where a cask on its list wants to be - that list is in
# home.nix and it is short. If that app belongs to someone else, replacing it is
# where Homebrew can ask for a password of its own; README.md is exact about
# that case and about all of this.
#
# Homebrew has to be installed before this runs. The preflight below checks for
# it before step 1, so a Mac without it is turned away before anything has been
# installed and before any password is asked for.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/dotfiles-link.sh
. "$DIR/lib/dotfiles-link.sh"
# shellcheck source=lib/flake-settings.sh
. "$DIR/lib/flake-settings.sh"
# shellcheck source=lib/personalize.sh
. "$DIR/lib/personalize.sh"
# shellcheck source=lib/git-identity.sh
. "$DIR/lib/git-identity.sh"
# shellcheck source=lib/install-report.sh
. "$DIR/lib/install-report.sh"
# shellcheck source=lib/homebrew-present.sh
. "$DIR/lib/homebrew-present.sh"

# Every step below resolves through ~/.dotfiles, so settle that path before
# anything is installed and before sudo is asked for. Refusing here costs the
# user nothing; refusing at the switch would cost them a Nix install and a
# password.
echo "==> Preflight: ~/.dotfiles"
# A failing command substitution in an assignment exits under `set -e`, so an
# unusable ~/.dotfiles stops the script right here.
PREFLIGHT="$(dotfiles_link_check "$DIR")"
if [ "$PREFLIGHT" = already ]; then
  echo "    this repository already is ~/.dotfiles"
else
  echo "    ok"
fi

# The other hard prerequisite, and it is checked here for the same reason: this
# configuration requires Homebrew, but the step that needs it is the last thing
# a switch does. Finding out then would cost the user a Nix install and a
# password before the bad news. This asks a path question only; it never runs
# Homebrew.
echo "==> Preflight: Homebrew"
# Not captured: it reports what it found itself, so no path to `brew` is ever
# held here. See the comment on the function.
dotfiles_homebrew_require

echo "==> Step 1: Determinate Nix"
echo "    This is the one and only step that asks for your password."
if command -v nix >/dev/null 2>&1; then
  echo "    nix already installed, skipping"
else
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  # shellcheck disable=SC1091
  if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    set +u
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh || true
    set -u
  fi
fi

echo "==> Step 2: symlink this repo to ~/.dotfiles"
dotfiles_link_apply "$DIR"

# Steps 3 and 4 offer THIS MACHINE'S real values as the defaults, never the
# ones already written in flake.nix; lib/personalize.sh explains why that is
# the one rule these prompts have to obey, and tests/bootstrap.test.sh holds
# them to it.
echo "==> Step 3: the account this configuration is built for"
personalize_user "$DIR/flake.nix"

echo "==> Step 4: your home directory"
personalize_home_directory "$DIR/flake.nix"

# Refuse now if the two answers still do not describe this machine - for
# instance because a prompt was answered with someone else's value.
flake_settings_check_machine "$DIR/flake.nix"

echo "==> Step 5: the untracked local files"
# These two are the seam. Everything specific to one machine or one employer
# lives in them, they are never committed, and this repo never reads their
# contents - it only arranges for them to be included. Seeding them with
# comments means the extension point is discoverable on the machine itself and
# not only in the README.

# shellcheck disable=SC2088  # the tilde is display text in a label, not a path
seed_local_file "$HOME/.zshrc.local" "~/.zshrc.local" <<'LOCAL'
# Machine-local shell configuration. Never committed; sourced last by ~/.zshrc,
# so anything here overrides the tracked configuration.
#
# This is where employer-specific settings belong. For example:
#
#   # A corporate network that intercepts TLS needs Node to trust its CA.
#   # export NODE_EXTRA_CA_CERTS="$HOME/certs/corporate-ca.pem"
#
#   # A proxy.
#   # export HTTPS_PROXY="http://proxy.example.invalid:8080"
#   # export HTTP_PROXY="$HTTPS_PROXY"
#   # export NO_PROXY="localhost,127.0.0.1"
#
#   # An internal package registry.
#   # npm config set registry https://registry.example.invalid/
LOCAL

# shellcheck disable=SC2088  # the tilde is display text in a label, not a path
seed_local_file "$HOME/.gitconfig.local" "~/.gitconfig.local" <<'LOCAL'
# Machine-local git configuration. Never committed, and included by the git
# config this repo generates.
#
# Your default identity belongs here:
#
#   [user]
#       name = Your Name
#       email = you@example.com
#
# An identity that should apply only inside ~/work goes in ~/.gitconfig.work
# instead - see README.md.
LOCAL

echo "==> Step 6: first build and switch"
# No sudo. Home Manager writes into $HOME, and its last activation step asks an
# already-installed Homebrew for the formulae and casks home.nix lists. Neither
# needs a privilege this script has not already got.
#
# `nix run ~/.dotfiles#home-manager` runs the Home Manager revision this repo's
# flake.lock pins, so the tool and the configuration it activates can never be
# two different versions.
#
# -b backup: a fresh macOS account already has files Home Manager wants to own
# (~/.zshrc, most often). Without this the very first switch aborts on the
# collision; with it the existing file is renamed to <name>.backup and left in
# place for you to read.
CONFIG_NAME="$(flake_settings_config_name "$DIR/flake.nix")"
# Said out loud rather than assumed: the architecture is detected, not
# configured, and this is the only place the user gets to see which of the two
# configurations is about to be built.
echo "    This Mac is $(uname -m), so the configuration is \"$CONFIG_NAME\"."
NIX_BIN="$(command -v nix || true)"
if [ -z "$NIX_BIN" ]; then
  echo "    nix is not on this shell's PATH, so the switch cannot run."
  echo "    The Determinate installer only adds nix to the PATH of new shells,"
  echo "    so a terminal opened before step 1 installed it will not have it."
  echo "    Open a new terminal and re-run ./bootstrap.sh."
  exit 1
fi
"$NIX_BIN" run "$HOME/.dotfiles#home-manager" -- \
  switch -b backup --flake "$HOME/.dotfiles#$CONFIG_NAME"

# Only now is this worth asking: the switch is what installs the git includes,
# so before it git could not have read the file step 5 just seeded. It stays
# silent unless git would have to invent an identity.
git_identity_report "    "

# The closing report, not a closing line. What this run installed is spread
# across ~/.nix-profile/bin and ~/Applications, none of it is visible from the
# shell this ran in, and a user who came from a personal dotfiles repo will go
# looking in /Applications and in `brew list` and find nothing in either. All
# three are expected states, and the moment to say so is here. The closing
# headline is the report's too: it is what knows whether anything landed, and
# it prints "==> Done." only when something did. See lib/install-report.sh.
install_report "    "
