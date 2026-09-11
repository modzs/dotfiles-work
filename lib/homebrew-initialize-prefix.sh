#!/usr/bin/env bash
# lib/homebrew-initialize-prefix.sh - create a Homebrew prefix and hand it to a
# user. The one privileged thing this repository does to Homebrew, and the only
# part of it that cannot be done from a rebuild.
#
#   homebrew-initialize-prefix.sh <prefix> <library> <user> <group>
#
# This script does not escalate anything. It expects to BE root already:
# bootstrap.sh runs it under the single announced `sudo` in this repository,
# after saying out loud what it is about to do, and nothing else ever runs it.
# Keeping the escalation at the call site rather than in here is deliberate -
# tests/safety.test.sh permits exactly one `sudo` in bootstrap.sh and nowhere
# else, so a second one anywhere fails the suite.
#
# Run once per machine. Everything afterwards - the symlinks into the Nix store,
# every `brew install` the Brewfile asks for - happens as the user, in a prefix
# that now belongs to them, which is what lets ./rebuild.sh promise it never
# asks for a password.
#
# The body is a port of `initialize_prefix` from nix-homebrew's modules/utils.sh,
# which is itself adapted from Homebrew's own install script. The directory
# lists, the chmod/chown/chgrp split and the order are kept recognisably the
# same so that a future reader can diff them.
#
#   BSD 2-Clause License
#   Copyright (c) 2009-present, Homebrew contributors
#   Copyright (c) 2023 Zhaofeng Li and the nix-homebrew contributors
#
# What is deliberately NOT ported: nix-homebrew's auto-migration. There is no
# path through this script that removes, converts or moves an existing Homebrew.
# It refuses an occupied prefix and says what it found, and that is the owner's
# explicit instruction - on a Mac someone else administers, deleting a package
# manager's tree is not a thing a setup script may decide to do.
#
# Must stay bash 3.2 and BSD-tool compatible - macOS ships no newer bash and no
# GNU coreutils. See AGENTS.md.
set -eu

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/homebrew-present.sh
. "$DIR/homebrew-present.sh"

if [ "$#" != 4 ]; then
  echo "usage: homebrew-initialize-prefix.sh <prefix> <library> <user> <group>" >&2
  echo "       This is run for you by ./bootstrap.sh. Run that instead." >&2
  exit 2
fi

HOMEBREW_PREFIX=$1
HOMEBREW_LIBRARY=$2
OWNER_NAME=$3
OWNER_GROUP=$4

# Resolved here rather than passed in as numbers, so the caller names a user and
# a group and this script is the only place that turns those into ids.
OWNER_UID=$(id -u "$OWNER_NAME") || {
  echo "ERROR: no account named '$OWNER_NAME' on this Mac." >&2
  exit 1
}
OWNER_GID=$(dscl . -read "/Groups/$OWNER_GROUP" PrimaryGroupID 2>/dev/null \
  | awk '($1 == "PrimaryGroupID:") { print $2 }')
if [ -z "$OWNER_GID" ]; then
  echo "ERROR: no group named '$OWNER_GROUP' on this Mac." >&2
  echo "       Homebrew's own installer gives its prefix to the 'admin' group," >&2
  echo "       and this repository follows it." >&2
  exit 1
fi

# Asked again, as root, immediately before writing. The preflight asked it too,
# but a preflight runs minutes and several steps earlier, and this is the one
# process on the machine running with enough privilege to do real damage if the
# answer changed in between.
#
# Judged for the owner's account and not for root's, which is the whole reason
# the state machine takes a uid. Asked as root, `[ -w ]` is true of every path
# on the machine, so a check written that way would report a prefix full of
# directories the user cannot write as ready to hand over.
STATE=$(dotfiles_homebrew_prefix_state "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY" "$OWNER_UID")
case $STATE in
  occupied)
    echo "ERROR: refusing to initialize $HOMEBREW_PREFIX." >&2
    dotfiles_homebrew_report_occupied "       " "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY"
    exit 1
    ;;
  unusable)
    echo "ERROR: refusing to initialize $HOMEBREW_PREFIX." >&2
    dotfiles_homebrew_report_unusable "       " \
      "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY" "$OWNER_UID"
    exit 1
    ;;
  managed)
    echo "    $HOMEBREW_PREFIX is already set up; nothing to do"
    exit 0
    ;;
esac

# --- the tools, by absolute path ----------------------------------------------
#
# nix-homebrew's list and nix-homebrew's reason: the GNU implementations of
# these behave differently, and this runs on a machine where a Nix profile may
# well have put GNU versions first on PATH.
STAT_PRINTF=("/usr/bin/stat" "-f")
PERMISSION_FORMAT="%A"
CHMOD=("/bin/chmod")
CHOWN=("/usr/sbin/chown")
CHGRP=("/usr/bin/chgrp")
MKDIR=("/bin/mkdir" "-p")
TOUCH=("/usr/bin/touch")
INSTALL=("/usr/bin/install" -d -o "root" -g "wheel" -m "0755")

get_permission() {
  "${STAT_PRINTF[@]}" "${PERMISSION_FORMAT}" "$1"
}

user_only_chmod() {
  [ -d "$1" ] && [[ "$(get_permission "$1")" != 75[0145] ]]
}

# --- the prefix ---------------------------------------------------------------

echo "    creating $HOMEBREW_PREFIX and giving it to $OWNER_NAME:$OWNER_GROUP"

# Kept relatively in sync with Homebrew's own Library/Homebrew/keg.rb, with one
# departure that is the point rather than a detail. Upstream's port also
# collects every prefix directory that already exists and is not writable, and
# chmods and chowns those to the user. That branch is deliberately absent here:
# a directory this repository did not create belongs to whatever put it there,
# and on a Mac an employer manages, taking it over is precisely the change this
# repository exists not to make. Such a directory makes the prefix `unusable`,
# the run refuses above, and the user is told which paths and why.
#
# The URL is deliberately not written out either: tests/safety.test.sh fails any
# script this repo runs whose text carries a Homebrew installer or clone URL,
# and that guard is worth more than a convenient link. Homebrew's source is a
# flake input now, and flake.nix is where its address belongs.

# zsh refuses to read from these directories if group writable
directories=(share/zsh share/zsh/site-functions)
zsh_dirs=()
for dir in "${directories[@]}"; do
  zsh_dirs+=("${HOMEBREW_PREFIX}/${dir}")
done

# What this step CREATES, taken from lib/homebrew-present.sh rather than listed
# again here. A second copy would be a second prefix layout: what that file
# inspects for ownership is this same list, so a prefix built from one and
# judged against the other would be refused by the very next command that
# looked at it.
#
# This is NOT what the marker promises, and the difference is the whole reason
# the prefix stopped locking itself out. The marker promises only that
# $HOMEBREW_PREFIX/bin and the library exist and are the user's - Homebrew
# deletes most of the rest itself once empty, so requiring them made a plain
# `brew uninstall` unrecoverable without another password. Widening the list
# below is fine; widening what dotfiles_homebrew_unusable requires to EXIST is
# what reinstates that. Read the comment on that function before you do.
mkdirs=()
while IFS= read -r dir; do
  if ! [ -d "$dir" ]; then
    mkdirs+=("$dir")
  fi
done < <(dotfiles_homebrew_prefix_directories "$HOMEBREW_PREFIX")

user_chmods=()
mkdirs_user_only=()
for dir in "${zsh_dirs[@]}"; do
  if [ ! -d "${dir}" ]; then
    mkdirs_user_only+=("${dir}")
  elif user_only_chmod "${dir}"; then
    user_chmods+=("${dir}")
  fi
done

if [ -d "${HOMEBREW_PREFIX}" ]; then
  # Only ever the zsh directories, and only ones the refusal above has already
  # established are this user's: zsh ignores a completions directory that is
  # group writable, so one left that way by an earlier tool has to be tightened.
  if [ "${#user_chmods[@]}" -gt 0 ]; then
    "${CHMOD[@]}" "u+rwx" "${user_chmods[@]}"
    "${CHMOD[@]}" "go-w" "${user_chmods[@]}"
  fi
else
  # The only branch that genuinely requires root, and the reason this script
  # exists separately at all. Everything after it is a chmod or a chown that a
  # user already owning the tree could have done themselves.
  "${INSTALL[@]}" "${HOMEBREW_PREFIX}"
fi

if [ "${#mkdirs[@]}" -gt 0 ]; then
  "${MKDIR[@]}" "${mkdirs[@]}"
  "${CHMOD[@]}" "ug=rwx" "${mkdirs[@]}"
  if [ "${#mkdirs_user_only[@]}" -gt 0 ]; then
    "${CHMOD[@]}" "go-w" "${mkdirs_user_only[@]}"
  fi
  "${CHOWN[@]}" "${OWNER_UID}" "${mkdirs[@]}"
  "${CHGRP[@]}" "${OWNER_GID}" "${mkdirs[@]}"
fi

if ! [ -d "${HOMEBREW_LIBRARY}" ]; then
  "${MKDIR[@]}" "${HOMEBREW_LIBRARY}"
fi
"${CHOWN[@]}" "-R" "${OWNER_UID}:${OWNER_GID}" "${HOMEBREW_LIBRARY}"

# The handover, verified rather than assumed. The marker is what every later run
# reads to decide that this step is done and that no password is needed again,
# so it has to be PROOF THAT THE PREFIX IS THE USER'S and not a record that this
# script reached the end. Writing it on a prefix that is not is what turned one
# unhandable directory into a machine that could never be bootstrapped or rebuilt
# again: bootstrap said "already set up", every switch said "not writable", and
# nothing in between ever looked.
UNUSABLE=$(dotfiles_homebrew_unusable \
  "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY" "$OWNER_UID")
if [ -n "$UNUSABLE" ]; then
  echo "ERROR: $HOMEBREW_PREFIX was not handed over, so it is not marked." >&2
  dotfiles_homebrew_report_unusable "       " \
    "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY" "$OWNER_UID"
  exit 1
fi

"${TOUCH[@]}" "${HOMEBREW_PREFIX}/${DOTFILES_HOMEBREW_MARKER}"

echo "    $HOMEBREW_PREFIX is ready; the rest of the setup needs no password"
