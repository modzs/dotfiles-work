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
STATE=$(dotfiles_homebrew_prefix_state "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY")
case $STATE in
  occupied)
    echo "ERROR: refusing to initialize $HOMEBREW_PREFIX." >&2
    dotfiles_homebrew_report_occupied "       " "$HOMEBREW_PREFIX" "$HOMEBREW_LIBRARY"
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

exists_but_not_writable() {
  [ -e "$1" ] && ! { [ -r "$1" ] && [ -w "$1" ] && [ -x "$1" ]; }
}

get_owner() {
  "${STAT_PRINTF[@]}" "%u" "$1"
}

file_not_owned() {
  [ "$(get_owner "$1")" != "${OWNER_UID}" ]
}

get_group() {
  "${STAT_PRINTF[@]}" "%g" "$1"
}

file_not_grpowned() {
  [ "$(get_group "$1")" != "${OWNER_GID}" ]
}

# --- the prefix ---------------------------------------------------------------

echo "    creating $HOMEBREW_PREFIX and giving it to $OWNER_NAME:$OWNER_GROUP"

# Kept relatively in sync with Homebrew's own Library/Homebrew/keg.rb. The URL
# is deliberately not written out: tests/safety.test.sh fails any script this
# repo runs whose text carries a Homebrew installer or clone URL, and that guard
# is worth more than a convenient link. Homebrew's source is a flake input now,
# and flake.nix is where its address belongs.
directories=(
  bin etc include lib sbin share opt var
  Frameworks
  etc/bash_completion.d lib/pkgconfig
  share/aclocal share/doc share/info share/locale share/man
  share/man/man1 share/man/man2 share/man/man3 share/man/man4
  share/man/man5 share/man/man6 share/man/man7 share/man/man8
  var/log var/homebrew var/homebrew/linked
  bin/brew
)
group_chmods=()
for dir in "${directories[@]}"; do
  if exists_but_not_writable "${HOMEBREW_PREFIX}/${dir}"; then
    group_chmods+=("${HOMEBREW_PREFIX}/${dir}")
  fi
done

# zsh refuses to read from these directories if group writable
directories=(share/zsh share/zsh/site-functions)
zsh_dirs=()
for dir in "${directories[@]}"; do
  zsh_dirs+=("${HOMEBREW_PREFIX}/${dir}")
done

directories=(
  bin etc include lib sbin share var opt
  share/zsh share/zsh/site-functions
  var/homebrew var/homebrew/linked
  Cellar Caskroom Frameworks
)
mkdirs=()
for dir in "${directories[@]}"; do
  if ! [ -d "${HOMEBREW_PREFIX}/${dir}" ]; then
    mkdirs+=("${HOMEBREW_PREFIX}/${dir}")
  fi
done

user_chmods=()
mkdirs_user_only=()
if [ "${#zsh_dirs[@]}" -gt 0 ]; then
  for dir in "${zsh_dirs[@]}"; do
    if [ ! -d "${dir}" ]; then
      mkdirs_user_only+=("${dir}")
    elif user_only_chmod "${dir}"; then
      user_chmods+=("${dir}")
    fi
  done
fi

chmods=()
if [ "${#group_chmods[@]}" -gt 0 ]; then
  chmods+=("${group_chmods[@]}")
fi
if [ "${#user_chmods[@]}" -gt 0 ]; then
  chmods+=("${user_chmods[@]}")
fi

chowns=()
chgrps=()
if [ "${#chmods[@]}" -gt 0 ]; then
  for dir in "${chmods[@]}"; do
    if file_not_owned "${dir}"; then
      chowns+=("${dir}")
    fi
    if file_not_grpowned "${dir}"; then
      chgrps+=("${dir}")
    fi
  done
fi

if [ -d "${HOMEBREW_PREFIX}" ]; then
  if [ "${#chmods[@]}" -gt 0 ]; then
    "${CHMOD[@]}" "u+rwx" "${chmods[@]}"
  fi
  if [ "${#group_chmods[@]}" -gt 0 ]; then
    "${CHMOD[@]}" "g+rwx" "${group_chmods[@]}"
  fi
  if [ "${#user_chmods[@]}" -gt 0 ]; then
    "${CHMOD[@]}" "go-w" "${user_chmods[@]}"
  fi
  if [ "${#chowns[@]}" -gt 0 ]; then
    "${CHOWN[@]}" "${OWNER_UID}" "${chowns[@]}"
  fi
  if [ "${#chgrps[@]}" -gt 0 ]; then
    "${CHGRP[@]}" "${OWNER_GID}" "${chgrps[@]}"
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

# Last, and only once everything above has succeeded. The marker is what every
# later run reads to decide that this step is done, so writing it early would
# turn a half-created prefix into one nothing ever finishes.
"${TOUCH[@]}" "${HOMEBREW_PREFIX}/${DOTFILES_HOMEBREW_MARKER}"

echo "    $HOMEBREW_PREFIX is ready; the rest of the setup needs no password"
