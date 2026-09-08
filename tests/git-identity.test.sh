#!/usr/bin/env bash
# Behaviour tests for the git identity seam.
#
# The promise README.md makes is: your identity lives in untracked files in your
# home directory, `~/.gitconfig.work` applies only inside `~/work`, and nothing
# tracked in this public repo carries a name or an email. All three are checked
# here by asking git itself, using the git config this configuration really
# generates, against a throwaway HOME.
# Assertion messages below name the untracked home-directory files by their
# conventional ~/ spelling. They are display text, never paths this script
# opens, so the tilde is not meant to expand.
# shellcheck disable=SC2088
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/git-identity.sh
. "$ROOT/lib/git-identity.sh"

dotfiles_test_parse_args "$@"

SYSTEM=aarch64-darwin
case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-darwin ;;
esac

# A fake home containing the git config this configuration generates, plus a
# work repository and a personal one.
make_home() {
  local generation home
  generation=$(nix build --no-link --print-out-paths ".#packages.$SYSTEM.default" 2>/dev/null) \
    || return 1
  home=$(dotfiles_test_tmproot dotfiles-git)
  mkdir -p "$home/.config/git" "$home/work/repo" "$home/personal/repo"
  cp "$generation/home-files/.config/git/config" "$home/.config/git/config"
  git -C "$home/work/repo" init -q
  git -C "$home/personal/repo" init -q
  printf '%s\n' "$home"
}

# GIT_CONFIG_NOSYSTEM, so a machine-wide /etc/gitconfig - which a corporate
# image or a CI runner may well have - cannot supply an identity and make these
# checks pass or fail for a reason that has nothing to do with this repo.
resolve() {
  local home=$1 repo=$2 key=$3
  HOME="$home" GIT_CONFIG_NOSYSTEM=1 git -C "$home/$repo" config --get "$key" 2>/dev/null || true
}

test_the_generated_config_carries_no_identity() {
  local home
  if ! command -v nix >/dev/null 2>&1; then
    skip "generated git config identity (nix not found)"
    return 0
  fi
  home=$(make_home) || fail "could not build the configuration"

  # No local files at all. An identity that showed up here would be one this
  # public repo had committed - the thing every clone and fork would inherit.
  assert_eq "$(resolve "$home" personal/repo user.name)" "" \
    "the generated git config supplies a user.name"
  assert_eq "$(resolve "$home" personal/repo user.email)" "" \
    "the generated git config supplies a user.email"

  pass "git: the generated config carries no name and no email of its own"
}

test_missing_local_files_are_not_an_error() {
  local home status=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "absent local files (nix not found)"
    return 0
  fi
  home=$(make_home) || fail "could not build the configuration"

  # Both includes point at files that do not exist. git must treat that as an
  # ordinary state, not a broken config - a fresh machine has neither file
  # until the user writes one.
  HOME="$home" GIT_CONFIG_NOSYSTEM=1 \
    git -C "$home/personal/repo" config --list >/dev/null 2>&1 || status=$?
  assert_eq "$status" 0 "git could not read a config whose includes point at absent files"

  pass "git: includes pointing at absent files are a normal state"
}

test_the_local_file_supplies_the_default_identity() {
  local home
  if ! command -v nix >/dev/null 2>&1; then
    skip "default identity (nix not found)"
    return 0
  fi
  home=$(make_home) || fail "could not build the configuration"
  printf '[user]\n\tname = Default Name\n\temail = default@example.invalid\n' \
    >"$home/.gitconfig.local"

  assert_eq "$(resolve "$home" personal/repo user.email)" default@example.invalid \
    "~/.gitconfig.local does not supply the default identity"

  pass "git: ~/.gitconfig.local supplies the identity everywhere"
}

test_the_work_file_applies_only_inside_work() {
  local home
  if ! command -v nix >/dev/null 2>&1; then
    skip "work identity scoping (nix not found)"
    return 0
  fi
  home=$(make_home) || fail "could not build the configuration"
  printf '[user]\n\tname = Default Name\n\temail = default@example.invalid\n' \
    >"$home/.gitconfig.local"
  printf '[user]\n\temail = work@example.invalid\n' >"$home/.gitconfig.work"

  assert_eq "$(resolve "$home" work/repo user.email)" work@example.invalid \
    "~/.gitconfig.work does not apply inside ~/work"
  assert_eq "$(resolve "$home" personal/repo user.email)" default@example.invalid \
    "~/.gitconfig.work leaked outside ~/work"
  # The keys it does not set still fall through to the default file, so a work
  # file holding only an email is a complete answer.
  assert_eq "$(resolve "$home" work/repo user.name)" "Default Name" \
    "a key absent from ~/.gitconfig.work did not fall through to ~/.gitconfig.local"

  pass "git: ~/.gitconfig.work applies inside ~/work and nowhere else"
}

test_a_preexisting_gitconfig_still_wins() {
  local home
  if ! command -v nix >/dev/null 2>&1; then
    skip "pre-existing ~/.gitconfig precedence (nix not found)"
    return 0
  fi
  home=$(make_home) || fail "could not build the configuration"
  printf '[user]\n\temail = default@example.invalid\n' >"$home/.gitconfig.local"
  printf '[user]\n\temail = pre-existing@example.invalid\n' >"$home/.gitconfig"

  # Asserted because it is surprising and because HOW-TO.md says so. Home
  # Manager writes the XDG config, ~/.config/git/config, and git reads
  # ~/.gitconfig afterwards - so a machine that already had one keeps using it.
  # This test exists to keep that documented behaviour true rather than to
  # endorse it; `git config --show-origin` is what tells a confused user which
  # file won.
  assert_eq "$(resolve "$home" personal/repo user.email)" pre-existing@example.invalid \
    "a pre-existing ~/.gitconfig no longer takes precedence - HOW-TO.md says it does"

  pass "git: a pre-existing ~/.gitconfig still takes precedence, as documented"
}

test_the_report_speaks_only_when_git_would_guess() {
  local home output
  home=$(dotfiles_test_tmproot dotfiles-git-report)

  # Nothing set anywhere: git would invent an identity for the next commit, and
  # that is the one state worth interrupting for.
  output=$(HOME="$home" GIT_CONFIG_NOSYSTEM=1 git_identity_report "  ")
  assert_contains "$output" "user.name" "the report is silent about a missing user.name"
  assert_contains "$output" ".gitconfig.local" \
    "the report does not name the file this setup writes"
  assert_contains "$output" ".gitconfig.work" \
    "the report does not mention the per-directory work identity"

  # A whole identity, wherever it comes from, is a correct setup. rebuild.sh
  # runs this on every switch, so a warning that printed anyway would be a
  # warning nobody reads.
  printf '[user]\n\tname = Someone\n\temail = someone@example.invalid\n' >"$home/.gitconfig"
  output=$(HOME="$home" GIT_CONFIG_NOSYSTEM=1 git_identity_report "  ")
  assert_eq "$output" "" "the report speaks about a machine that already has an identity"

  pass "git: the identity report speaks only when git would have to guess"
}

test_the_generated_config_carries_no_identity
test_missing_local_files_are_not_an_error
test_the_local_file_supplies_the_default_identity
test_the_work_file_applies_only_inside_work
test_a_preexisting_gitconfig_still_wins
test_the_report_speaks_only_when_git_would_guess

test_summary
