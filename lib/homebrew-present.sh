#!/usr/bin/env bash
# lib/homebrew-present.sh - the single definition of where this configuration's
# Homebrew lives, what state its prefix is in, and whether it is ours.
#
# This file used to answer one question - "is there a Homebrew here" - and
# bootstrap.sh refused a Mac that answered no. That is no longer the right
# question. This configuration now installs Homebrew itself, from a pinned flake
# input, so an absent Homebrew is the ordinary state of a fresh machine rather
# than a reason to turn it away. The refusal it still has to make is the
# opposite one: a prefix that already holds a Homebrew this repository did not
# create is never converted, migrated or deleted, and finding that out has to
# happen before Nix is installed rather than at the end of a switch.
#
# Four callers, and keeping the rules here is what stops them drifting apart:
#
#   - bootstrap.sh's preflight, which reports the prefix state before anything
#     is installed and refuses an occupied one;
#   - lib/homebrew-initialize-prefix.sh, the one privileged step, which asks the
#     same question again as root before it writes anything;
#   - home.nix's prefix-setup activation step, which SOURCES THIS FILE out of
#     the Nix store and calls dotfiles_homebrew_prefix_link. There is no second
#     implementation of these rules to keep in step with this one;
#   - home.nix's Brewfile step, which sources it out of the store too and calls
#     dotfiles_homebrew_find to locate the `brew` setup just installed. That
#     search used to be written out a second time inside that step, and the two
#     copies drifting is not hypothetical: one of them fed a space-separated
#     string to an unquoted `for`, so a HOMEBREW_PREFIX containing a space split
#     into two paths that do not exist and bootstrap refused a Mac the rebuild
#     would have accepted. There is one copy now, and
#     tests/homebrew.test.sh still runs both sides against the same prefixes.
#
# Nothing in this file runs Homebrew, and nothing in it escalates privilege.
# The privileged half lives in lib/homebrew-initialize-prefix.sh and is run
# under the single announced `sudo` in bootstrap.sh.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# --- where this configuration's Homebrew lives --------------------------------
#
# Decided by the architecture, and by nothing else. This is not a preference:
# Homebrew's prebuilt bottles are built for these two prefixes, and a Homebrew
# anywhere else builds everything from source. It is the same rule nix-homebrew
# applies, and the same rule home.nix bakes into the generated `brew` at
# evaluation time - so these two functions and that generated file have to
# agree, and tests/homebrew.test.sh compares them.
#
# HOMEBREW_PREFIX is deliberately NOT consulted here. It answers "where is the
# Homebrew this machine already uses", which was the right question while this
# repo only ever drove someone else's installation. The question now is where
# THIS configuration's Homebrew belongs, and the environment does not get to
# move it: the generated `brew` carries its prefix inside it, so a prefix that
# came from somewhere else would produce a `brew` that lies about where it is.

# The Homebrew prefix for this Mac.
dotfiles_homebrew_prefix() {
  local arch
  arch=$(uname -m)
  case $arch in
    arm64) printf '%s\n' /opt/homebrew ;;
    x86_64) printf '%s\n' /usr/local ;;
    *)
      echo "ERROR: unrecognized CPU architecture '$arch'." >&2
      echo "       This configuration builds for arm64 and x86_64 Macs only." >&2
      return 1
      ;;
  esac
}

# The Homebrew library directory for this Mac. Not "$prefix/Library" on both:
# on Intel the prefix is /usr/local, which is shared with everything else on the
# machine, so Homebrew keeps its library one level down. This is upstream
# Homebrew's layout, not a choice made here.
dotfiles_homebrew_library() {
  local arch
  arch=$(uname -m)
  case $arch in
    arm64) printf '%s\n' /opt/homebrew/Library ;;
    x86_64) printf '%s\n' /usr/local/Homebrew/Library ;;
    *)
      echo "ERROR: unrecognized CPU architecture '$arch'." >&2
      echo "       This configuration builds for arm64 and x86_64 Macs only." >&2
      return 1
      ;;
  esac
}

# The marker file whose presence means "this prefix was created by a Nix-managed
# Homebrew setup and needs no privileged initialization again".
#
# It is nix-homebrew's filename, deliberately and not by accident. The marker is
# an on-disk contract between whatever set a prefix up and whatever finds it
# later, and using the same name means nix-homebrew and this repository hand the
# same prefix back and forth instead of each initializing over the other. The
# name says nix_darwin because nix-homebrew wrote it first; this repository
# still has no nix-darwin input and tests/safety.test.sh still fails if one
# appears.
DOTFILES_HOMEBREW_MARKER=".managed_by_nix_darwin"

# The fake HOMEBREW_REPOSITORY the setup step builds inside the library. Also
# nix-homebrew's name, and it says out loud what it is to anyone who finds it.
DOTFILES_HOMEBREW_REPOSITORY_DIR=".homebrew-is-managed-by-nix"

# --- is what is there ours ----------------------------------------------------

# True when $1 is a symlink pointing into the Nix store, which is the only shape
# anything this configuration puts in the prefix has.
#
# One level of readlink, not `readlink -f`. nix-homebrew resolves the whole
# chain because it also has to recognise a `./result` link into the store; the
# only links here are the ones dotfiles_homebrew_prefix_link writes, and those
# point straight at a store path. Anything else - a real directory, a link
# somewhere else, a link through another link - is not ours, which is the
# direction this has to fail in.
dotfiles_homebrew_is_ours() {
  local path=$1 target
  [ -L "$path" ] || return 1
  target=$(readlink "$path") || return 1
  case $target in
    /nix/store/*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when something is at $1 and it is not ours. An absent path is not
# occupied; a path we created is not occupied; everything else is.
dotfiles_homebrew_is_occupied() {
  local path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 1
  dotfiles_homebrew_is_ours "$path" && return 1
  return 0
}

# The paths in the prefix that something else is sitting on, one per line, or
# nothing at all. These are the two places a Homebrew installation announces
# itself: the library directory that holds its code, and the launcher.
dotfiles_homebrew_occupants() {
  local prefix=$1 library=$2 code launcher
  code="$library/Homebrew"
  launcher="$prefix/bin/brew"
  if dotfiles_homebrew_is_occupied "$code"; then
    printf '%s\n' "$code"
  fi
  if dotfiles_homebrew_is_occupied "$launcher"; then
    printf '%s\n' "$launcher"
  fi
}

# What state the prefix at $1 (with library $2) is in. Prints exactly one word:
#
#   occupied  something that is not ours is in the way. Never converted, never
#             migrated, never deleted - the run stops and says what it found.
#   managed   the marker is there, so the privileged setup has already run and
#             must not run again.
#   fresh     neither. The prefix may not exist at all, or may exist and be
#             empty of Homebrew, which is the normal state of /usr/local on any
#             Mac.
#
# Occupancy is tested first, because a prefix carrying both the marker and a
# foreign Homebrew is a prefix nothing here may write to.
dotfiles_homebrew_prefix_state() {
  local prefix=$1 library=$2
  if [ -n "$(dotfiles_homebrew_occupants "$prefix" "$library")" ]; then
    printf 'occupied\n'
    return 0
  fi
  if [ -e "$prefix/$DOTFILES_HOMEBREW_MARKER" ]; then
    printf 'managed\n'
    return 0
  fi
  printf 'fresh\n'
}

# What to tell a user whose prefix is occupied. Shared by the preflight and the
# activation step, because they are the same news and it should not be phrased
# two ways.
#
# $1 is the indent, $2 the prefix, $3 the library.
dotfiles_homebrew_report_occupied() {
  local indent=$1 prefix=$2 library=$3 occupant
  echo "${indent}$prefix already contains a Homebrew this repository did not" >&2
  echo "${indent}install. It is in the way at:" >&2
  dotfiles_homebrew_occupants "$prefix" "$library" | while IFS= read -r occupant; do
    echo "${indent}  $occupant" >&2
  done
  echo "${indent}" >&2
  echo "${indent}Nothing has been changed. This repository installs its own" >&2
  echo "${indent}Homebrew from a pinned source, and it will not convert, migrate" >&2
  echo "${indent}or delete one it did not create - on a work Mac that is exactly" >&2
  echo "${indent}the kind of software nobody should remove on your behalf." >&2
  echo "${indent}" >&2
  echo "${indent}If you want this repository to manage Homebrew on this Mac," >&2
  echo "${indent}uninstall the existing one yourself first - Homebrew documents" >&2
  echo "${indent}how at https://docs.brew.sh/FAQ - and run ./bootstrap.sh again." >&2
}

# --- the unprivileged half, which activation runs -----------------------------

# Point an already-initialized prefix at the Homebrew in the Nix store.
#
#   $1 prefix      /opt/homebrew or /usr/local
#   $2 library     $1/Library or $1/Homebrew/Library
#   $3 code        the patched Library/Homebrew directory in the Nix store
#   $4 launcher    the generated bin/brew in the Nix store
#
# Every write below lands inside a prefix bootstrap.sh has already chowned to
# this user, so this must never need root, and it must fail rather than try when
# the prefix is not in that state. That is the whole division of labour: root
# once, in bootstrap.sh, and never again on a rebuild.
#
# Absolute macOS tool paths, like nix-homebrew's, and for its reason: Home
# Manager replaces PATH with a fixed list of Nix store paths before running an
# activation script, and `ln -shf` is BSD spelling that GNU coreutils does not
# accept.
dotfiles_homebrew_prefix_link() {
  local prefix=$1 library=$2 code=$3 launcher=$4
  local repository state
  # The two paths this writes, named before they are used. That is not style:
  # tests/safety.test.sh forbids any script here from having a `brew` token in
  # command position, and it permits one in an assignment because an assignment
  # names a path rather than running it. Writing the destination inline would
  # have the scanner read `ln`'s last argument as an invocation.
  local bin_brew="$prefix/bin/brew"

  state=$(dotfiles_homebrew_prefix_state "$prefix" "$library") || return 1

  if [ "$state" = occupied ]; then
    echo "dotfiles-work: refusing to touch $prefix." >&2
    dotfiles_homebrew_report_occupied "       " "$prefix" "$library"
    return 1
  fi

  if [ "$state" != managed ]; then
    echo "dotfiles-work: $prefix has not been set up yet, so Homebrew cannot" >&2
    echo "       be installed into it." >&2
    echo "" >&2
    echo "       Creating that prefix is the one thing this configuration needs" >&2
    echo "       a password for, so it happens once, in ./bootstrap.sh, and" >&2
    echo "       never during a rebuild. Run ./bootstrap.sh on this Mac." >&2
    return 1
  fi

  # Ownership, asked as the only question that matters: can this user write the
  # two directories the links go in. A prefix set up for somebody else carries
  # the marker and is still unusable, and finding that out here - with a
  # sentence about where the fix is - beats a bare "Permission denied" from ln.
  if [ ! -d "$library" ] || [ ! -w "$library" ]; then
    echo "dotfiles-work: $library is not writable by $(whoami)." >&2
    echo "       $prefix carries the marker that says it was set up for a" >&2
    echo "       Nix-managed Homebrew, but not for this account." >&2
    echo "       Re-run ./bootstrap.sh, which will say what it finds." >&2
    return 1
  fi
  if [ ! -d "$prefix/bin" ] || [ ! -w "$prefix/bin" ]; then
    echo "dotfiles-work: $prefix/bin is not writable by $(whoami)." >&2
    echo "       Re-run ./bootstrap.sh, which will say what it finds." >&2
    return 1
  fi

  # The library is synthesized rather than being a checkout: code from the Nix
  # store, state in the prefix. That is nix-homebrew's central idea and the
  # reason a pinned Homebrew cannot drift - there is no git repository here for
  # `brew update` to fast-forward.
  /bin/ln -shf "$code" "$library/Homebrew"

  # A fake HOMEBREW_REPOSITORY, because Homebrew still expects one to exist.
  # Rebuilt every time rather than created behind a marker: it is four empty
  # directories, and a half-written one from an interrupted switch has to heal
  # itself on the next.
  repository="$library/$DOTFILES_HOMEBREW_REPOSITORY_DIR"
  /bin/rm -rf "$repository"
  /bin/mkdir -p "$repository/.git"
  /bin/chmod 775 "$repository" "$repository/.git"
  /usr/bin/touch "$repository/.git/HEAD"

  /bin/ln -shf "$launcher" "$bin_brew"
}

# --- which brew a rebuild would hand the Brewfile to --------------------------
#
# A different question from the one above, and it stays a different question.
# The prefix is where this configuration's Homebrew BELONGS; this is where the
# Homebrew step LOOKS, and it honours HOMEBREW_PREFIX because that is Homebrew's
# own answer to "where am I" and because a machine told where Homebrew is and
# not having it there has no usable Homebrew. On any ordinary machine the two
# coincide, and tests/homebrew.test.sh asserts that they do.
#
# home.nix's Brewfile step sources this file and calls the two functions below,
# so there is nothing here to keep in step with a second copy.

# Describe, for a human, where this machine would look. For the failure message
# only - it is prose, not a list anything iterates over. It used to be both, and
# a caller splitting it on whitespace is what made a `HOMEBREW_PREFIX` with a
# space in it come out as two paths that do not exist.
dotfiles_homebrew_searched() {
  local searched="/opt/homebrew/bin/brew /usr/local/bin/brew"
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    searched="$HOMEBREW_PREFIX/bin/brew"
  fi
  printf '%s\n' "$searched"
}

# Print the path of the Homebrew this machine would use, or nothing at all.
# Returns 0 either way: "absent" is an answer, not an error, and the caller
# decides what it means.
#
# A prefix from the environment is one path and is checked as one path; only the
# two literal candidates are a list to iterate. Deriving both from a single
# space-separated string is what broke this once - see the note above
# dotfiles_homebrew_searched - so this does not do that.
dotfiles_homebrew_find() {
  local candidate found=""

  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    found="$HOMEBREW_PREFIX/bin/brew"
    if [ -x "$found" ]; then
      printf '%s\n' "$found"
    fi
    return 0
  fi

  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

# --- bootstrap.sh's preflight -------------------------------------------------

# Say what this Mac's Homebrew prefix is and what is going to happen to it, or
# refuse before anything has been installed.
#
# Position is the point. This runs before the Nix install and before the first
# password prompt, so a Mac whose prefix this repository may not touch is turned
# away having had nothing done to it. bootstrap.sh states the same principle
# about ~/.dotfiles: refusing early costs nothing, refusing at the switch costs
# a Nix install and a password.
#
# $1 and $2 are the prefix and library. bootstrap.sh resolves them once, at the
# top, and hands the same pair to this and to the step that creates them - so
# there is exactly one place in that script where the answer is decided. Taking
# them as arguments is also what lets tests/homebrew.test.sh run this against a
# stand-in prefix instead of against whatever the machine running the suite
# happens to have at /opt/homebrew.
#
# Deliberately reports rather than returns. A caller that captured a path would
# be a script holding a ready-to-run `brew` in a variable, and
# tests/safety.test.sh cannot see through a variable. Nothing here needs one, so
# nothing here holds one.
dotfiles_homebrew_preflight() {
  local prefix=$1 library=$2 state found

  state=$(dotfiles_homebrew_prefix_state "$prefix" "$library") || return 1

  case $state in
    occupied)
      echo "ERROR: this Mac already has a Homebrew of its own." >&2
      dotfiles_homebrew_report_occupied "       " "$prefix" "$library"
      echo "       Nothing has been installed yet, so stopping here costs you" >&2
      echo "       nothing." >&2
      return 1
      ;;
    managed)
      echo "    $prefix is already set up for a Nix-managed Homebrew"
      found=$(dotfiles_homebrew_find)
      if [ -n "$found" ]; then
        echo "    a rebuild will hand the Brewfile to $found"
      fi
      ;;
    fresh)
      echo "    $prefix has no Homebrew in it"
      echo "    this run will create it, which needs your password once"
      ;;
  esac
}
