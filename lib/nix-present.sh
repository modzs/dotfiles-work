#!/usr/bin/env bash
# Where `nix` is, and what to say when it is nowhere. Sourced by bootstrap.sh.
#
# This is one function in a library rather than five lines in bootstrap.sh, for
# the reason lib/personalize.sh exists: bootstrap.sh cannot be run end to end by
# a test - it installs Nix and asks for a password twice, and it resolves
# Homebrew's prefix from `uname -m` and then inspects the real one - so a
# refusal left in its body is a refusal nothing can exercise.
# tests/bootstrap.test.sh drives this one with a PATH that has no `nix` on it.
#
# It is bootstrap.sh's ONLY owner for that refusal, and that is the point of it
# rather than a tidiness claim. The guard used to sit at step 7, after the one
# `sudo`, so a Mac whose switch could never run still spent the user's password
# first. The switch now uses the path this returns and tests nothing again:
# nothing between the two steps can remove Nix, and a second emptiness test
# there would be a second place able to stop the run after the password is gone.
#
# rebuild.sh deliberately keeps its own. Its explanation names the terminal
# ./bootstrap.sh ran in and sends the user to run ./rebuild.sh in a new one,
# which is different advice rather than this advice with a word changed.

# Print the absolute path to `nix` on stdout, or explain on stderr and fail.
#
# Callers run under `set -e`, where a failing command substitution in an
# assignment ends the script - so `NIX_BIN="$(dotfiles_nix_path)"` is both the
# lookup and the refusal.
dotfiles_nix_path() {
  local found
  # `|| true` so the lookup itself cannot abort the caller before the guard
  # below has said anything.
  found="$(command -v nix || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi

  echo "ERROR: nix is not on this shell's PATH, so the switch cannot run." >&2
  echo "       The Determinate installer only adds nix to the PATH of new" >&2
  echo "       shells, so a terminal opened before step 1 installed it will" >&2
  echo "       not have it." >&2
  echo "       Open a new terminal and re-run ./bootstrap.sh." >&2
  return 1
}
