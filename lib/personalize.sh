#!/usr/bin/env bash
# lib/personalize.sh - the interactive steps that make this configuration
# describe THIS machine, and the seeding of the untracked local files.
#
# Sourced by bootstrap.sh. It lives here rather than inline so that
# tests/bootstrap.test.sh can drive it with scripted answers instead of a
# person, because the one rule these prompts have to obey is easy to get wrong
# and expensive to get wrong:
#
#   Wherever a default is offered, the default is THIS MACHINE'S CURRENT VALUE,
#   never the value already written in the config.
#
# The repository this one replaces offered its *configured* machine name as the
# default for the machine-name prompt, so pressing Enter - the thing a reader
# does when a prompt looks preconfigured - silently renamed the Mac. Nothing
# here renames anything, but the same shape of mistake would silently build a
# configuration for the wrong account or the wrong home directory.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# Ask which account this configuration is for. Does nothing, and consumes no
# answer, when it already matches. $1 is flake.nix.
personalize_user() {
  local file=$1 real configured answer
  real=$(whoami)
  configured=$(flake_settings_user "$file") || return 1

  if [ "$configured" = "$real" ]; then
    echo "    flake.nix already matches \"$real\", nothing to do."
    return 0
  fi

  echo "    You are \"$real\". flake.nix is configured for \"$configured\"."
  # The default is $real. Enter keeps this machine, not the stranger's.
  read -r -p "    Username [$real]: " answer || true
  answer="${answer:-$real}"
  flake_settings_set_user "$file" "$answer" || return 1
  echo "    Set to \"$answer\". Review the change with: git diff flake.nix"
}

# Ask where this account's home directory is. Does nothing, and consumes no
# answer, when the configured one already is this one. $1 is flake.nix.
personalize_home_directory() {
  local file=$1 configured answer user
  configured=$(flake_settings_home_directory "$file") || return 1

  # -ef compares what the paths resolve to, so a home reached through a symlink
  # - ordinary on a managed Mac - is not reported as a mismatch.
  if [ "$HOME" -ef "$configured" ]; then
    echo "    flake.nix manages \"$configured\", which is your home. Nothing to do."
    return 0
  fi

  echo "    Your home directory is \"$HOME\"."
  echo "    flake.nix is configured to manage \"$configured\"."
  echo "    A managed Mac does not always put a home under /Users/<username>."
  # The default is $HOME. Enter keeps this machine, not the stranger's.
  read -r -p "    Home directory [$HOME]: " answer || true
  answer="${answer:-$HOME}"

  # Written back as `null` when it is just /Users/<user> after all, so the
  # ordinary case keeps the line that needs no maintenance.
  user=$(flake_settings_user "$file") || return 1
  if [ "$answer" = "/Users/$user" ]; then
    flake_settings_set_home_directory "$file" null || return 1
  else
    flake_settings_set_home_directory "$file" "$answer" || return 1
  fi
  echo "    Set to \"$answer\". Review the change with: git diff flake.nix"
}

# Create one of the untracked local files, with the guidance on stdin. An
# existing file is never touched: it is the user's, this repo has never read it,
# and it is the one place their employer-specific settings can live.
# $1 is the path, $2 the name to show.
seed_local_file() {
  local path=$1 label=$2
  if [ -e "$path" ]; then
    echo "    $label already exists, leaving it alone."
    return 0
  fi
  cat >"$path"
  echo "    Created $label."
}
