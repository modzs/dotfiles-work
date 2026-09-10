#!/usr/bin/env bash
# Behaviour tests for the report bootstrap.sh prints when it has finished.
#
# The report is the only thing a first-time user reads, and the failure that
# produced this file was a report that was true and said too little: a complete
# install, "==> Done.", and a user who concluded nothing had been installed
# because /Applications was empty, `brew list` was empty, and the shell he had
# just run bootstrap.sh from could not find a single tool.
#
# Two properties, both checked here:
#
# - the report says what was installed, where it went, and why this terminal
#   cannot see it;
# - it answers, rather than assumes, whether the NEXT terminal can. Nothing
#   this repository writes puts the profile on PATH; a line the Nix installer
#   adds to /etc/zshrc does, and on a managed Mac that line can be taken away
#   again. A switch that succeeds and a shell where every command is "not
#   found" is the one state with no error message anywhere, so a report that
#   quietly implied all was well would recreate the original failure exactly.
#
# The reachability probe is a seam on purpose: these checks replace
# install_report_login_path with one that returns a known PATH, so the decision
# and the wording are tested without depending on how the machine running the
# suite happens to have /etc/zshrc set up. The last check exercises the real
# probe, for the one property no stub can prove.
#
# Nothing here activates anything or touches the real home directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/install-report.sh
. "$ROOT/lib/install-report.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 7

# A home directory that looks like one bootstrap.sh has just finished with: a
# profile carrying a few tools. Echoes the path.
install_report_fixture_home() {
  local tmp home
  tmp=$(dotfiles_test_tmproot dotfiles-report)
  home="$tmp/home"
  mkdir -p "$home/.nix-profile/bin"
  touch "$home/.nix-profile/bin/rg" \
    "$home/.nix-profile/bin/fd" \
    "$home/.nix-profile/bin/wezterm"
  printf '%s\n' "$home"
}

# Make the probe answer with $1, or fail when $1 is the word "unavailable".
#
# The answer goes in a global rather than a local: the replacement function is
# called long after this one has returned, and under `set -u` a local it closed
# over is simply gone.
INSTALL_REPORT_STUB_PATH=""
install_report_stub_probe() {
  INSTALL_REPORT_STUB_PATH=$1
  if [ "$1" = unavailable ]; then
    install_report_login_path() { return 1; }
  else
    install_report_login_path() { printf '%s\n' "$INSTALL_REPORT_STUB_PATH"; }
  fi
}

# Re-sourcing puts the real definitions back, which is both the simplest way
# and the one that cannot drift from the file under test.
install_report_restore_probe() {
  # shellcheck source=lib/install-report.sh
  . "$ROOT/lib/install-report.sh"
}

# --- what was installed, and why this terminal cannot see it ------------------

test_the_report_says_what_was_installed_and_where() {
  local home output
  home=$(install_report_fixture_home)
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  output=$(HOME="$home" install_report "    ")
  install_report_restore_probe

  # The count is read off the profile, so it is a number the user can check
  # with the very command the report gives them.
  assert_contains "$output" "holds 3 command-line tools" \
    "the report should say how many tools the profile really carries"
  # shellcheck disable=SC2088  # a literal to find in the report's text, not a path to expand
  assert_contains "$output" "~/.nix-profile/bin" \
    "the report should say where the tools went"
  assert_contains "$output" "Home Manager Apps" \
    "the report should say where the two terminal apps went"
  assert_contains "$output" "Spotlight will not index" \
    "the report should say that Spotlight will not find the apps"

  # The three places a user coming from a personal dotfiles repo will look and
  # find nothing, unless this says so first.
  assert_contains "$output" "Open a new terminal" \
    "the report should say the tools need a new shell"
  assert_contains "$output" "installs no Homebrew" \
    "the report should say Homebrew is deliberately absent"

  pass "report: says what was installed, where it went, and why this shell cannot see it"
}

test_an_empty_profile_is_reported_as_a_broken_install() {
  local home output
  home=$(install_report_fixture_home)
  rm -rf "$home/.nix-profile"
  # The state this must not paper over: a login shell that would find the
  # profile on PATH, because the /etc/zshrc line adds ~/.nix-profile/bin
  # whether or not the directory exists. The reachability check alone would
  # therefore confirm a new terminal finds tools that are not there.
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  output=$(HOME="$home" install_report "    ")
  install_report_restore_probe

  assert_contains "$output" "WARNING" \
    "a profile with no tools in it is a broken install, not a quiet zero"
  assert_not_contains "$output" "0 command-line tools" \
    "the report must not read as a successful install of nothing"
  assert_not_contains "$output" "Checked: a new login shell does find them" \
    "the report must not confirm reachability of tools that do not exist"
  assert_contains "$output" "bootstrap.sh again" \
    "the report should say what to do about it"

  pass "report: an empty or missing profile reads as a broken install"
}

test_the_report_mentions_the_zshrc_backup_only_when_there_is_one() {
  local home without with
  home=$(install_report_fixture_home)
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  without=$(HOME="$home" install_report)
  # -b backup renames an existing ~/.zshrc rather than failing the switch, and
  # nothing else in the run mentions that the old file still exists.
  touch "$home/.zshrc.backup"
  with=$(HOME="$home" install_report)
  install_report_restore_probe

  assert_not_contains "$without" ".zshrc.backup" \
    "a home with no backup should not be told about one"
  assert_contains "$with" "moved to ~/.zshrc.backup" \
    "a home whose ~/.zshrc was renamed should be told where it went"

  pass "report: names ~/.zshrc.backup only when the switch really made one"
}

# --- does the next terminal see any of it? ------------------------------------

test_an_unreachable_profile_is_a_loud_warning_naming_etc_zshrc() {
  local home output
  home=$(install_report_fixture_home)
  # A successful install and a login shell that will not see it: exactly the
  # state a re-deployed /etc/zshrc leaves a managed Mac in.
  install_report_stub_probe "/usr/bin:/bin:/usr/sbin:/sbin"

  output=$(HOME="$home" install_report "    ")
  install_report_restore_probe

  assert_contains "$output" "WARNING" \
    "an install the next terminal cannot see should be a warning, not a footnote"
  assert_contains "$output" "/etc/zshrc" \
    "the warning should name the file to look at"
  assert_contains "$output" "grep -i nix /etc/zshrc" \
    "the warning should give the command that checks it"

  # Detect without owning. This repository must never edit /etc, and the
  # warning must not imply that it will.
  assert_contains "$output" "will not edit /etc" \
    "the warning should say plainly that this repo cannot fix it"
  assert_contains "$output" "Everything listed above is installed" \
    "the warning should not leave the user thinking the install failed too"

  pass "report: warns, names /etc/zshrc, and does not offer to fix it"
}

test_a_reachable_profile_produces_no_warning() {
  local home output
  home=$(install_report_fixture_home)
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  output=$(HOME="$home" install_report "    ")
  install_report_restore_probe

  assert_not_contains "$output" "WARNING" \
    "a working install must not be warned about"
  assert_contains "$output" "Checked: a new login shell does find them" \
    "a working install should say so, because that is the confirmation asked for"

  pass "report: says nothing alarming when a new login shell will find the tools"
}

test_an_unanswerable_check_is_never_reported_as_fine() {
  local home output
  home=$(install_report_fixture_home)
  install_report_stub_probe unavailable

  output=$(HOME="$home" install_report "    ")
  install_report_restore_probe

  # The whole episode this file exists for was a false all-clear. A check that
  # could not run must read as unverified, never as verified.
  assert_contains "$output" "Not checked" \
    "an unanswerable check should say it did not answer"
  assert_not_contains "$output" "Checked: a new login shell does find them" \
    "an unanswerable check must never claim the tools are reachable"
  assert_contains "$output" "/etc/zshrc" \
    "an unanswerable check should still say where to look"

  pass "report: an unanswerable reachability check reads as unverified, not fine"
}

# --- the one property no stub can prove ---------------------------------------

test_the_probe_does_not_inherit_this_process_path() {
  local home path status=0

  home=$(install_report_fixture_home)

  # bootstrap.sh reaches the report with nix, and everything else the profile
  # carries, already on its own PATH - step 1 sourced it in. A probe that
  # inherited that would agree the tools are reachable no matter what a fresh
  # terminal would really get, which is the one way this check could be
  # silently wrong in the direction of "all good".
  #
  # The fixture profile is a temp directory that no startup file on any machine
  # mentions, so a probe that answers with it can only have inherited it.
  path=$(HOME="$home" PATH="$home/.nix-profile/bin:$PATH" install_report_login_path) \
    || status=$?

  if [ "$status" != 0 ]; then
    skip "login-shell probe (no usable zsh to probe with)"
    return 0
  fi

  case ":$path:" in
    *:"$home/.nix-profile/bin":*)
      fail "the reachability probe inherited the calling process's PATH" ;;
  esac

  pass "report: the reachability probe answers for a fresh shell, not for this one"
}

test_the_report_says_what_was_installed_and_where
test_an_empty_profile_is_reported_as_a_broken_install
test_the_report_mentions_the_zshrc_backup_only_when_there_is_one
test_an_unreachable_profile_is_a_loud_warning_naming_etc_zshrc
test_a_reachable_profile_produces_no_warning
test_an_unanswerable_check_is_never_reported_as_fine
test_the_probe_does_not_inherit_this_process_path

test_summary
