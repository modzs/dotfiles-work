#!/usr/bin/env bash
# lib/dotfiles-link.sh - the single definition of "point ~/.dotfiles at this repo".
#
# Sourced by bootstrap.sh and rebuild.sh. home.nix resolves its out-of-store
# symlinks through ~/.dotfiles rather than through wherever the clone happens
# to sit, so that name has to be settled before anything is built.
#
# The bare `ln -sfn "$DIR" ~/.dotfiles` this replaces silently does the wrong
# thing when ~/.dotfiles already exists as a real directory: -n only guards
# against an existing *symlink*, so against a directory ln happily creates the
# link *inside* it and exits 0.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# Resolve a path to its physical location, or print nothing when it is not a
# directory we can enter (a regular file, a dangling link, an unreadable dir).
dotfiles_link_resolve() {
  ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null || true
}

# Decide what ~/.dotfiles needs, without touching anything.
# Prints one of:
#   link     - it is absent, or a symlink we should (re)point at this repo
#   already  - it IS this repo, so there is nothing to link
# Returns 1 with an explanation on stderr when ~/.dotfiles is a real path that
# is not this repo, because every step after it would build the wrong tree.
#
# $1 is the repository root, already resolved with `pwd -P`.
dotfiles_link_check() {
  local repo_root=$1
  local link_path="$HOME/.dotfiles"
  local resolved_link

  # A symlink is safe to replace: `ln -sfn` swaps it in place, whether it
  # already points here or somewhere stale.
  if [ -L "$link_path" ] || [ ! -e "$link_path" ]; then
    echo link
    return 0
  fi

  # A real file or directory lives there. The one benign case is the most
  # natural install of all: the repo was cloned to ~/.dotfiles itself. Compare
  # resolved paths, so a symlink anywhere in either path cannot fool the check.
  resolved_link=$(dotfiles_link_resolve "$link_path")
  if [ -n "$resolved_link" ] && [ "$resolved_link" = "$repo_root" ]; then
    echo already
    return 0
  fi

  echo "ERROR: $link_path already exists and is not a symlink." >&2
  echo "       It is not this repository, which is at:" >&2
  echo "         $repo_root" >&2
  echo "       Refusing to continue: every step after this one points at" >&2
  echo "       ~/.dotfiles and would build the wrong tree." >&2
  echo "       Move that path aside, or re-run this script from inside it." >&2
  return 1
}

# Point ~/.dotfiles at this repo. Refuses, without side effects, in the case
# dotfiles_link_check rejects. $1 is the repository root, resolved with `pwd -P`.
dotfiles_link_apply() {
  local action
  action=$(dotfiles_link_check "$1") || return 1
  if [ "$action" = already ]; then
    echo "    ~/.dotfiles is this repository already, nothing to link"
    return 0
  fi
  ln -sfn "$1" "$HOME/.dotfiles"
}
