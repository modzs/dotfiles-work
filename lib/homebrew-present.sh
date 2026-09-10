#!/usr/bin/env bash
# lib/homebrew-present.sh - the single definition of "is there a Homebrew here".
#
# Sourced by bootstrap.sh, which asks this BEFORE it installs Nix. That order is
# the whole point: this configuration requires Homebrew, and the Homebrew step
# is the last thing activation does, so without a check up front a user on a Mac
# with no Homebrew pays for a Nix install and a password prompt and only then
# gets told. bootstrap.sh states the same principle about ~/.dotfiles: refusing
# early costs nothing, refusing at the switch costs a Nix install.
#
# Detection is a path existence test and nothing else. This library must never
# run Homebrew - not to check its version, not to ask where it lives.
#
# THE RULE HERE MUST MATCH home.nix's activation step. If the two disagree,
# bootstrap.sh passes and the rebuild fails later, which is exactly the failure
# this file exists to prevent. Both say: HOMEBREW_PREFIX is authoritative when
# the environment sets it - look only there, because a machine told where
# Homebrew is and not having it there has no usable Homebrew, and quietly using
# a different one would be worse - and otherwise try the two prefixes macOS
# Homebrew supports, Apple silicon first. Change one, change the other.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# Print the locations this machine would look in, space separated. Split out so
# the failure message names the place it actually looked rather than a guess.
dotfiles_homebrew_searched() {
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    printf '%s\n' "$HOMEBREW_PREFIX/bin/brew"
  else
    printf '%s\n' "/opt/homebrew/bin/brew /usr/local/bin/brew"
  fi
}

# Print the path of the Homebrew this machine would use, or nothing at all.
# Returns 0 either way: "absent" is an answer, not an error, and the caller
# decides what it means.
dotfiles_homebrew_find() {
  local candidate
  for candidate in $(dotfiles_homebrew_searched); do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

# Print the path of the Homebrew this machine would use, or explain and fail.
# The explanation matches the activation step's in substance, because a user who
# hits one has to be told the same thing either way.
dotfiles_homebrew_require() {
  local found
  found=$(dotfiles_homebrew_find)
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi

  echo "ERROR: no Homebrew at $(dotfiles_homebrew_searched)." >&2
  cat >&2 <<'MISSING'
       This configuration drives Homebrew and requires it, but it deliberately
       does not install it. Homebrew's installer needs your password and writes
       outside your home directory, so running it is your decision to make, not
       this repository's - and on a Mac you do not administer it may not be
       yours to make at all.

       Install it yourself from https://brew.sh and run ./bootstrap.sh again.
       Nothing has been installed yet, so stopping here costs you nothing.
MISSING
  return 1
}
