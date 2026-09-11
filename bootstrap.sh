#!/usr/bin/env bash
# Bootstrap from nothing to a configured home directory on macOS.
# Run this once. After it finishes, use ./rebuild.sh for every later change.
#
# This asks for your password TWICE, both times here and never again: once for
# the Nix installer in step 1, and once in step 5 to create Homebrew's prefix
# and hand it to you. ./rebuild.sh asks for neither. No machine name, no /etc,
# no macOS system settings, and no other user's account touched.
#
# Two parts of this reach outside your home directory, and both are deliberate.
#
# Step 5 creates Homebrew's standard prefix - /opt/homebrew on Apple silicon,
# /usr/local on Intel - and gives it to your account. That is the one privileged
# thing this repository does itself, it happens once, and it refuses outright if
# a Homebrew it did not install is already sitting there: nothing here converts,
# migrates or deletes one. Afterwards Homebrew's code is a symlink into the Nix
# store at the version flake.lock pins, so there is no self-updating checkout in
# your prefix.
#
# The switch in step 7 then hands that Homebrew a generated Brewfile, and
# Homebrew installs what it lists into its prefix and /Applications. It
# uninstalls nothing. The one thing it will replace is an application already
# sitting where a cask on its list wants to be - that list is in home.nix and it
# is short. If that app belongs to someone else, replacing it is where Homebrew
# can ask for a password of its own; README.md is exact about that case and
# about all of this.
#
# The preflight below looks at the prefix before step 1, so a Mac this
# repository may not set Homebrew up on is turned away before anything has been
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

# The other hard prerequisite, and it is checked here for the same reason. This
# configuration installs its own Homebrew, so an absent one is fine - but a
# prefix that already holds somebody else's is not, and that is a refusal worth
# making before a Nix install and a password rather than three steps later.
# This asks path questions only; it never runs Homebrew.
#
# Resolved once, here, and handed to both the preflight and step 5. The prefix
# is decided by the architecture and by nothing else - see the comment in
# lib/homebrew-present.sh - and deciding it twice in one script is how the two
# would come to disagree.
HOMEBREW_PREFIX_PATH="$(dotfiles_homebrew_prefix)"
HOMEBREW_LIBRARY_PATH="$(dotfiles_homebrew_library)"
echo "==> Preflight: Homebrew's prefix"
# Not captured: it reports what it found itself, so no path to `brew` is ever
# held here. See the comment on the function.
dotfiles_homebrew_preflight "$HOMEBREW_PREFIX_PATH" "$HOMEBREW_LIBRARY_PATH"

echo "==> Step 1: Determinate Nix"
echo "    This asks for your password. Step 5 asks once more, and that is all."
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

echo "==> Step 5: Homebrew's prefix"
# The one privileged thing this repository does, and the last check has just
# passed - so by here everything that can refuse this run already has. Creating
# the prefix before knowing the account and the home directory were right would
# mean writing outside $HOME for a run that then stops.
#
# This is the ONLY sudo in this repository. It runs a tracked script, with
# arguments named here, and that script escalates nothing itself: it expects to
# be root already. tests/safety.test.sh permits exactly this one call and fails
# on a second anywhere.
#
# Skipped entirely when the prefix is already set up. Together with step 1
# skipping an existing Nix, that is what makes a re-run of ./bootstrap.sh ask
# for no password at all.
case "$(dotfiles_homebrew_prefix_state "$HOMEBREW_PREFIX_PATH" "$HOMEBREW_LIBRARY_PATH")" in
  managed)
    echo "    $HOMEBREW_PREFIX_PATH is already set up; no password needed"
    ;;
  occupied)
    # The preflight said this too, before Nix was installed. Saying it again is
    # not redundancy for its own sake: the preflight ran several steps ago, and
    # this is the line immediately before the one that would write.
    echo "ERROR: refusing to set up $HOMEBREW_PREFIX_PATH." >&2
    dotfiles_homebrew_report_occupied "       " \
      "$HOMEBREW_PREFIX_PATH" "$HOMEBREW_LIBRARY_PATH"
    exit 1
    ;;
  *)
    echo "    About to create $HOMEBREW_PREFIX_PATH and give it to $(whoami)."
    echo "    That needs your password once. Nothing is removed, and no"
    echo "    existing Homebrew is touched - there is none here to touch."
    echo "    Homebrew's own code will be a symlink into the Nix store."
    # Guarded rather than left to `set -e`, because the most likely failure
    # here is a cancelled or mistyped password, and the bare message sudo
    # prints for that says nothing about what state the machine is in. Nothing
    # outside $HOME has been touched at this point, and saying so is the
    # difference between a stopped run and an alarming one.
    if ! sudo "$DIR/lib/homebrew-initialize-prefix.sh" \
      "$HOMEBREW_PREFIX_PATH" "$HOMEBREW_LIBRARY_PATH" "$(whoami)" admin; then
      echo "ERROR: Homebrew's prefix was not created, so this run stops here." >&2
      echo "       Nothing outside your home directory has been changed." >&2
      echo "       If you cancelled or mistyped the password, run" >&2
      echo "       ./bootstrap.sh again - it picks up where it left off." >&2
      echo "       If you do not have admin rights on this Mac, this" >&2
      echo "       repository cannot be used on it; README.md says why." >&2
      exit 1
    fi
    ;;
esac

echo "==> Step 6: the untracked local files"
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

echo "==> Step 7: first build and switch"
# No password. Home Manager writes into $HOME, points the prefix step 5 created
# at the Homebrew in the Nix store, and asks that Homebrew for the formulae and
# casks home.nix lists. All of it happens as you, in directories you now own,
# which is why ./rebuild.sh never needs a password either.
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
# across two package managers - ~/.nix-profile/bin from Nix, the Homebrew
# prefix and /Applications from the Brewfile step - and none of the Nix half is
# visible from the shell this ran in. Both are expected states, and the moment
# to say so is here. The closing headline is the report's too: it is what knows
# whether anything landed, and it prints "==> Done." only when something did.
# See lib/install-report.sh.
install_report "    "
