#!/usr/bin/env bash
# lib/git-identity.sh - say something only when git would have to invent an
# identity for the next commit.
#
# Sourced by bootstrap.sh and rebuild.sh. The answer is only meaningful after a
# switch, because the switch is what installs home.nix's includes of
# ~/.gitconfig.local and ~/.gitconfig.work.
#
# The one rule here, and the reason this is not a bigger report: it never
# states or implies which config file wins. It asks git what it resolves, and
# speaks only when git resolves nothing - the single state that is unambiguously
# wrong, whichever file the answer would have come from. An identity that
# deliberately lives in ~/.gitconfig, or only inside a work directory via
# includeIf, is a correct setup, and a warning that prints on every rebuild
# forever is one nobody reads.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# True when git resolves $1 to a non-empty value. An unreadable config - an
# unparsable file pulled in by an include, say - exits 128 rather than 1, and
# that is not the same machine as one that simply sets nothing, so it is
# reported separately by the caller.
#
# Asked from $HOME rather than the current directory, so the config of whatever
# repository the script happens to sit in is not read as the machine's answer.
git_identity_status() {
  local key=$1 value status=0
  value="$(git -C "$HOME" config --get "$key" 2>/dev/null)" || status=$?
  if [ "$status" != 0 ] && [ "$status" != 1 ]; then
    echo unreadable
    return 0
  fi
  if [ -z "$value" ]; then
    echo unset
  else
    echo set
  fi
}

# Warn, or say nothing at all. $1 is an optional indent so bootstrap.sh's step
# margin is preserved.
git_identity_report() {
  local indent=${1:-}
  local name email

  name=$(git_identity_status user.name)
  email=$(git_identity_status user.email)

  if [ "$name" = unreadable ] || [ "$email" = unreadable ]; then
    printf '%sHeads up: git cannot read this machine'\''s config, so it can say nothing\n' "$indent"
    printf '%sabout your identity. Run: git config --list\n' "$indent"
    return 0
  fi

  [ "$name" = unset ] || [ "$email" = unset ] || return 0

  printf '%sHeads up: git resolves no %s here, so it will invent an identity\n' \
    "$indent" "$(git_identity_missing_keys "$name" "$email")"
  printf '%sfor whatever you commit next. Set it in the untracked file this\n' "$indent"
  printf '%ssetup includes:\n' "$indent"
  [ "$name" = set ] \
    || printf '%s  git config --file ~/.gitconfig.local user.name "Your Name"\n' "$indent"
  [ "$email" = set ] \
    || printf '%s  git config --file ~/.gitconfig.local user.email "you@example.com"\n' "$indent"
  printf '%sFor an identity that applies only inside ~/work, write the same keys\n' "$indent"
  printf '%sto ~/.gitconfig.work instead. See README.md.\n' "$indent"
}

# Name exactly the keys git resolves to nothing. Half an identity is a real
# state and reporting it as "no identity" would be wrong.
git_identity_missing_keys() {
  local name=$1 email=$2
  if [ "$name" = unset ] && [ "$email" = unset ]; then
    echo "user.name and no user.email"
  elif [ "$name" = unset ]; then
    echo "user.name"
  else
    echo "user.email"
  fi
}
