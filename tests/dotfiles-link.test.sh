#!/usr/bin/env bash
# Behaviour tests for lib/dotfiles-link.sh.
#
# home.nix resolves the neovim and wezterm configurations through ~/.dotfiles,
# so what that name points at decides which files the switch installs. Every
# check here runs against a throwaway HOME, never the real one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/dotfiles-link.sh
. "$ROOT/lib/dotfiles-link.sh"

dotfiles_test_parse_args "$@"

# A sandbox with a fake HOME and a fake repository inside it.
make_sandbox() {
  local root
  root=$(dotfiles_test_tmproot dotfiles-link)
  mkdir -p "$root/home" "$root/repo"
  printf '%s\n' "$root"
}

test_absent_dotfiles_is_linked() {
  local sb repo
  sb=$(make_sandbox)
  repo=$(cd "$sb/repo" && pwd -P)

  assert_eq "$(HOME="$sb/home" dotfiles_link_check "$repo")" link \
    "an absent ~/.dotfiles should be reported as linkable"

  HOME="$sb/home" dotfiles_link_apply "$repo" >/dev/null \
    || fail "linking an absent ~/.dotfiles failed"
  # shellcheck disable=SC2088  # the tilde is display text in a message, not a path
  assert_eq "$(readlink "$sb/home/.dotfiles")" "$repo" \
    "~/.dotfiles does not point at the repository"

  pass "link: an absent ~/.dotfiles is created pointing at this repository"
}

test_a_stale_symlink_is_repointed() {
  local sb repo
  sb=$(make_sandbox)
  repo=$(cd "$sb/repo" && pwd -P)
  mkdir -p "$sb/elsewhere"
  ln -sfn "$sb/elsewhere" "$sb/home/.dotfiles"

  HOME="$sb/home" dotfiles_link_apply "$repo" >/dev/null \
    || fail "repointing a stale ~/.dotfiles failed"
  assert_eq "$(readlink "$sb/home/.dotfiles")" "$repo" \
    "a stale ~/.dotfiles was not repointed at this repository"

  pass "link: a symlink pointing somewhere else is repointed"
}

test_the_repo_cloned_at_dotfiles_needs_no_link() {
  local sb repo
  # The most natural install of all: the repository was cloned to ~/.dotfiles
  # itself. There is nothing to link, and nothing to refuse.
  sb=$(make_sandbox)
  mkdir -p "$sb/home/.dotfiles"
  repo=$(cd "$sb/home/.dotfiles" && pwd -P)

  assert_eq "$(HOME="$sb/home" dotfiles_link_check "$repo")" already \
    "a repository that already is ~/.dotfiles should need no link"

  HOME="$sb/home" dotfiles_link_apply "$repo" >/dev/null \
    || fail "a repository that already is ~/.dotfiles was refused"
  # shellcheck disable=SC2088  # the tilde is display text in a message, not a path
  [ -d "$sb/home/.dotfiles" ] && [ ! -L "$sb/home/.dotfiles" ] \
    || fail "~/.dotfiles was replaced by a symlink to itself"

  pass "link: a repository cloned at ~/.dotfiles is left exactly as it is"
}

test_a_real_directory_in_the_way_is_refused() {
  local sb repo
  # `ln -sfn` against an existing *directory* creates the link INSIDE it and
  # exits 0, which is how a bare ln silently builds the wrong tree. Refusing is
  # the only safe answer, and it has to happen before anything is installed.
  sb=$(make_sandbox)
  repo=$(cd "$sb/repo" && pwd -P)
  mkdir -p "$sb/home/.dotfiles/someone-elses-stuff"

  ! HOME="$sb/home" dotfiles_link_check "$repo" >/dev/null 2>&1 \
    || fail "a real directory at ~/.dotfiles was accepted"
  ! HOME="$sb/home" dotfiles_link_apply "$repo" >/dev/null 2>&1 \
    || fail "a real directory at ~/.dotfiles was linked over"
  [ ! -e "$sb/home/.dotfiles/repo" ] \
    || fail "a link was created inside the existing ~/.dotfiles directory"
  [ -d "$sb/home/.dotfiles/someone-elses-stuff" ] \
    || fail "the existing ~/.dotfiles directory was disturbed"

  pass "link: a real directory at ~/.dotfiles is refused, not linked into"
}

test_a_regular_file_in_the_way_is_refused() {
  local sb repo
  sb=$(make_sandbox)
  repo=$(cd "$sb/repo" && pwd -P)
  printf 'not a repo\n' >"$sb/home/.dotfiles"

  ! HOME="$sb/home" dotfiles_link_apply "$repo" >/dev/null 2>&1 \
    || fail "a regular file at ~/.dotfiles was linked over"
  assert_eq "$(cat "$sb/home/.dotfiles")" "not a repo" \
    "the regular file at ~/.dotfiles was overwritten"

  pass "link: a regular file at ~/.dotfiles is refused, not overwritten"
}

test_absent_dotfiles_is_linked
test_a_stale_symlink_is_repointed
test_the_repo_cloned_at_dotfiles_needs_no_link
test_a_real_directory_in_the_way_is_refused
test_a_regular_file_in_the_way_is_refused

test_summary
