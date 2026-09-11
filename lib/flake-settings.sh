#!/usr/bin/env bash
# lib/flake-settings.sh - the single definition of "what is this configuration
# built for, and does it match this machine".
#
# flake.nix carries exactly two adjustable values, both on one line each:
#
#   user = "someone";
#   homeDirectory = null;          # or "/some/path"
#
# bootstrap.sh writes them, rebuild.sh reads them, and both check them against
# the machine before anything is built. Keeping the parsing here means the two
# callers cannot drift apart, and means the tests can exercise the real code.
#
# The architecture is deliberately NOT one of those values. flake.nix builds
# both Darwin architectures from the same source, so nothing has to be edited
# to move between an Apple silicon and an Intel Mac: the configuration name is
# "<user>@<system>" and the system is read off the machine.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# --- reading ------------------------------------------------------------------

# Print the configured username, or fail with an explanation.
flake_settings_user() {
  local file=$1 value
  value=$(sed -nE 's/^[[:space:]]*user = "([^"]*)";.*/\1/p' "$file" | head -n1)
  if [ -z "$value" ]; then
    echo "ERROR: could not find the single 'user = \"...\";' line in $file." >&2
    echo "       Edit that line by hand before continuing." >&2
    return 1
  fi
  printf '%s\n' "$value"
}

# Print the configured home directory as flake.nix resolves it: the literal
# path when one is set, and "/Users/<user>" when the line reads `null`.
# Fails when the line is missing or holds something this parser does not
# understand, because guessing would be worse than stopping.
flake_settings_home_directory() {
  local file=$1 user raw
  user=$(flake_settings_user "$file") || return 1
  raw=$(sed -nE 's/^[[:space:]]*homeDirectory = ([^;]*);.*/\1/p' "$file" | head -n1)
  case $raw in
    "")
      echo "ERROR: could not find the single 'homeDirectory = ...;' line in $file." >&2
      echo "       Edit that line by hand before continuing." >&2
      return 1
      ;;
    null)
      printf '%s\n' "/Users/$user"
      ;;
    \"*\")
      # Strip the surrounding quotes.
      raw=${raw#\"}
      printf '%s\n' "${raw%\"}"
      ;;
    *)
      echo "ERROR: the 'homeDirectory' line in $file is neither null nor a" >&2
      echo "       quoted path. It reads: $raw" >&2
      return 1
      ;;
  esac
}

# The Nix system string for the Mac this is running on.
flake_settings_system() {
  local arch
  arch=$(uname -m)
  case $arch in
    arm64) echo aarch64-darwin ;;
    x86_64) echo x86_64-darwin ;;
    *)
      echo "ERROR: unrecognized CPU architecture '$arch'." >&2
      echo "       This configuration builds for arm64 and x86_64 Macs only." >&2
      return 1
      ;;
  esac
}

# The flake output name to switch to: "<user>@<system>".
flake_settings_config_name() {
  local file=$1 user system
  user=$(flake_settings_user "$file") || return 1
  system=$(flake_settings_system) || return 1
  printf '%s@%s\n' "$user" "$system"
}

# --- writing ------------------------------------------------------------------
#
# Rewritten with awk rather than `sed -i`, and the whole line is regenerated
# from the known format instead of being pattern-substituted. A username or a
# home directory is arbitrary text, and a sed replacement would have to escape
# whatever delimiter it chose out of it. awk takes the value through -v, where
# it is data and never pattern.

# Print the path that actually holds $1's bytes, following a symlink chain to
# its end. flake.nix is a file a user may well have symlinked into place, and a
# rewrite has to land on the file rather than replace the link with a regular
# one. There is no `readlink -f` to lean on: macOS ships BSD readlink, so the
# chain is walked by hand, with a bound so a loop of links stops rather than
# spins.
flake_settings_resolve() {
  local path=$1 target hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 32 ]; then
      echo "ERROR: too many levels of symbolic links at $1." >&2
      return 1
    fi
    target=$(readlink "$path") || return 1
    case $target in
      /*) path=$target ;;
      *) path=$(dirname "$path")/$target ;;
    esac
  done
  printf '%s\n' "$path"
}

# Replace the value on the single `<key> = ...;` line in $1. $2 is the key, $3
# is the already-formatted Nix expression to put there (a quoted string, or
# `null`). Fails without touching the file if that line is not there exactly
# once.
#
# The commit at the end is a rename, not a copy over the original. `cat "$tmp"
# >"$file"` truncates the target and only then starts writing, so an
# interruption anywhere in that window leaves an empty or half-written
# flake.nix - and this is the file bootstrap personalises, so it is the one a
# first-time user is least able to reconstruct. A rename is atomic: the path
# holds either the old file or the new one, never a partial.
#
# A plain `mv` is not enough on its own, because it would regress the two
# properties the copy had for free, so both are restored explicitly:
#
#   - the temp file is created beside the target and given the target's mode,
#     because mktemp makes it 0600 and a rename keeps the source's permissions;
#   - the rename lands on the *resolved* path, so a symlinked flake.nix is
#     written through rather than replaced by a regular file.
#
# Beside the target rather than in TMPDIR for a third reason: rename is only
# atomic within one filesystem, and TMPDIR need not be on the target's.
flake_settings_write() {
  local file=$1 key=$2 literal=$3 count real dir mode tmp
  count=$(grep -cE "^[[:space:]]*$key = [^;]*;" "$file" || true)
  if [ "$count" != 1 ]; then
    echo "ERROR: expected exactly one '$key = ...;' line in $file, found $count." >&2
    return 1
  fi
  real=$(flake_settings_resolve "$file") || return 1
  mode=$(stat -f '%Lp' "$real") || return 1
  dir=$(dirname "$real")
  # Beside the target on purpose, never in TMPDIR: rename is only atomic within
  # one filesystem. See the note above this function before moving it.
  tmp=$(mktemp "$dir/.flake-settings.XXXXXX") || return 1
  awk -v key="$key" -v literal="$literal" '
    !written && $0 ~ "^[[:space:]]*" key " = [^;]*;" {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) key " = " literal ";"
      written = 1
      next
    }
    { print }
  ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$real" || { rm -f "$tmp"; return 1; }
}

# A value that has to survive a round trip through a Nix string literal and a
# shell. Rejecting is the honest answer: a home directory holding a quote or a
# backslash is not something this repo can write correctly, and writing it
# wrongly would produce a flake.nix that does not parse.
flake_settings_valid_value() {
  case $1 in
    "" | *\"* | *\\* | *$'\n'*) return 1 ;;
    *) return 0 ;;
  esac
}

flake_settings_set_user() {
  local file=$1 value=$2
  if ! flake_settings_valid_value "$value"; then
    echo "ERROR: '$value' cannot be written into flake.nix." >&2
    echo "       A username must not be empty or contain a quote or a backslash." >&2
    return 1
  fi
  flake_settings_write "$file" user "\"$value\""
}

# $2 is an absolute path, or the literal string "null" to mean "derive it from
# the username", which is what a normal macOS account wants.
flake_settings_set_home_directory() {
  local file=$1 value=$2
  if [ "$value" = null ]; then
    flake_settings_write "$file" homeDirectory null
    return
  fi
  if ! flake_settings_valid_value "$value"; then
    echo "ERROR: that home directory cannot be written into flake.nix." >&2
    echo "       It must not be empty or contain a quote or a backslash." >&2
    return 1
  fi
  case $value in
    /*) : ;;
    *)
      echo "ERROR: '$value' is not an absolute path." >&2
      return 1
      ;;
  esac
  flake_settings_write "$file" homeDirectory "\"$value\""
}

# --- checking against the machine ---------------------------------------------

# Compare what flake.nix is built for against who is running this and where
# their home is. Home Manager's own activation refuses to run on a mismatch,
# but it does so after a full build and it cannot know that this repo keeps
# both answers on two editable lines - so this says what to do about it.
#
# $1 is flake.nix. Returns 1 and explains on stderr when they disagree.
flake_settings_check_machine() {
  local file=$1 configured_user configured_home real_user
  configured_user=$(flake_settings_user "$file") || return 1
  configured_home=$(flake_settings_home_directory "$file") || return 1
  real_user=$(whoami)

  if [ "$configured_user" != "$real_user" ]; then
    echo "ERROR: this configuration is built for the user \"$configured_user\"," >&2
    echo "       but you are \"$real_user\"." >&2
    echo "       Fix the single 'user = ' line in $file, or run ./bootstrap.sh," >&2
    echo "       which offers this machine's real values as the defaults." >&2
    return 1
  fi

  # -ef compares what the two paths resolve to, so a home reached through a
  # symlink - which is ordinary on a managed Mac - is not reported as a
  # mismatch. Home Manager's activation compares the same way.
  if [ ! "$HOME" -ef "$configured_home" ]; then
    echo "ERROR: this configuration manages \"$configured_home\"," >&2
    echo "       but your home directory is \"$HOME\"." >&2
    echo "       Refusing to continue: building it would write into a directory" >&2
    echo "       that is not yours." >&2
    echo "       Set the single 'homeDirectory = ' line in $file to:" >&2
    echo "         homeDirectory = \"$HOME\";" >&2
    echo "       or run ./bootstrap.sh, which offers to do it for you." >&2
    return 1
  fi
}
