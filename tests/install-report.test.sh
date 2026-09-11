#!/usr/bin/env bash
# Behaviour tests for the report bootstrap.sh prints when it has finished.
#
# The report is the only thing a first-time user reads, and the failure that
# produced this file was a report that was true and said too little: a complete
# install, "==> Done.", and a user who concluded nothing had been installed
# because the shell he had just run bootstrap.sh from could not find a single
# tool, and nothing said where the two halves of the install had gone.
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
# suite happens to have /etc/zshrc set up. The last two checks exercise the real
# probe, for the properties no stub can prove.
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
dotfiles_test_expect 12

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

  output=$(HOME="$home" install_report "    " /stand-in/prefix)
  install_report_restore_probe

  # The count is read off the profile, so it is a number the user can check
  # with the very command the report gives them.
  assert_contains "$output" "==> Done." \
    "the report supplies the closing verdict, and here it is a good one"
  assert_contains "$output" "holds 3 command-line tools" \
    "the report should say how many tools the profile really carries"
  # shellcheck disable=SC2088  # a literal to find in the report's text, not a path to expand
  assert_contains "$output" "~/.nix-profile/bin" \
    "the report should say where the tools went"
  assert_contains "$output" "/Applications" \
    "the report should say where the application casks went"
  assert_contains "$output" "brew list" \
    "the report should give the command that shows the Homebrew half"

  # The shell the user is standing in is the one place they will look and find
  # nothing, unless this says so first.
  assert_contains "$output" "Open a new terminal" \
    "the report should say the tools need a new shell"
  # Reversed, deliberately, and with the whole reason recorded here: this repo
  # used to tell the user it would never install Homebrew, and it now does
  # install one. A closing report that still said the old thing would be the
  # clearest possible example of the failure this file exists to prevent - a
  # run that did one thing while saying it did another.
  assert_contains "$output" "pinned by flake.lock" \
    "the report should say the Homebrew it installed is pinned"
  assert_not_contains "$output" "installs no Homebrew" \
    "the report still claims this repo never installs Homebrew, which is no longer true"

  pass "report: says what was installed, where it went, and why this shell cannot see it"
}

test_the_report_points_at_the_homebrew_path_line_too() {
  local home output
  home=$(install_report_fixture_home)
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  output=$(HOME="$home" install_report "    " /stand-in/prefix)
  install_report_restore_probe

  # The omission this closes: the report probed the Nix half and pointed the
  # user at a fix when it failed, and said nothing at all about whether their
  # shell can see the Homebrew half. Silence about one of two package managers
  # reads as an answer, and the answer it reads as is "fine".
  # shellcheck disable=SC2016  # the literal the report prints, not an expansion
  assert_contains "$output" 'eval "$(/stand-in/prefix/bin/brew shellenv)"' \
    "the report should give the line that puts Homebrew on PATH, naming the real prefix"
  assert_contains "$output" "did not check that half" \
    "the report must say the Homebrew half was not probed, rather than implying it was"

  # The line this file must never print. Nothing here reads Homebrew's
  # environment, so the report may not say it is reachable - the same bound the
  # Nix half observes by probing before it claims anything.
  assert_not_contains "$output" "Homebrew's tools are already" \
    "the report claims Homebrew is reachable, which nothing here has checked"

  pass "report: the Homebrew half gets the same pointer the Nix half gets"
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

  output=$(HOME="$home" install_report "    " /stand-in/prefix) || true
  install_report_restore_probe

  assert_contains "$output" "WARNING" \
    "a profile with no tools in it is a broken install, not a quiet zero"
  assert_not_contains "$output" "0 command-line tools" \
    "the report must not read as a successful install of nothing"
  assert_not_contains "$output" "Checked: a new login shell does find them" \
    "the report must not confirm reachability of tools that do not exist"
  assert_not_contains "$output" "==> Done." \
    "an empty profile must not be stamped as a finished run"
  # What to do about it has to be something that works from here. This shell
  # has no nix on its PATH - bootstrap.sh sourced the Determinate profile into
  # its own process only - so re-running bootstrap.sh restarts the Nix
  # installer rather than the switch.
  assert_contains "$output" "Open a new terminal, then run ./rebuild.sh" \
    "the report should say what actually works from here"

  pass "report: an empty or missing profile reads as a broken install"
}

test_only_a_profile_proven_empty_fails_the_run() {
  local home status

  home=$(install_report_fixture_home)

  # install_report is bootstrap.sh's last statement, so what it returns is what
  # the script returns - and `./bootstrap.sh && <next step>`, or an MDM wrapper
  # on a managed Mac, reads exactly that. The boundary matters as much as the
  # claim: only a profile the report has PROVEN empty is a failed run.
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"
  status=0
  HOME="$home" install_report "" /stand-in/prefix >/dev/null || status=$?
  assert_eq "$status" 0 "a complete run must exit 0"

  # Installed but out of reach: the tools are all there and only PATH is
  # wrong. That is the warning this change added, not a failed bootstrap.
  install_report_stub_probe "/usr/bin:/bin"
  status=0
  HOME="$home" install_report "" /stand-in/prefix >/dev/null || status=$?
  assert_eq "$status" 0 "an unreachable but populated profile must not fail the run"

  # And the third state has to survive in the status too. A check that could
  # not answer is unverified - never failure, never fine.
  install_report_stub_probe unavailable
  status=0
  HOME="$home" install_report "" /stand-in/prefix >/dev/null || status=$?
  assert_eq "$status" 0 "a check that could not answer must not fail the run"

  rm -rf "$home/.nix-profile"
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"
  status=0
  HOME="$home" install_report "" /stand-in/prefix >/dev/null || status=$?
  [ "$status" != 0 ] \
    || fail "a run that installed nothing exited 0, so it reported success"

  install_report_restore_probe

  pass "report: only a profile proven empty makes the run fail"
}

test_the_report_mentions_the_zshrc_backup_only_when_there_is_one() {
  local home without with
  home=$(install_report_fixture_home)
  install_report_stub_probe "$home/.nix-profile/bin:/usr/bin:/bin"

  without=$(HOME="$home" install_report "" /stand-in/prefix)
  # -b backup renames an existing ~/.zshrc rather than failing the switch, and
  # nothing else in the run mentions that the old file still exists.
  touch "$home/.zshrc.backup"
  with=$(HOME="$home" install_report "" /stand-in/prefix)
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

  output=$(HOME="$home" install_report "    " /stand-in/prefix)
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

  output=$(HOME="$home" install_report "    " /stand-in/prefix)
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

  output=$(HOME="$home" install_report "    " /stand-in/prefix)
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

# --- the two properties no stub can prove -------------------------------------

test_a_startup_file_that_prints_is_not_read_as_path() {
  local home output status=0

  home=$(install_report_fixture_home)

  # These startup files belong to whoever administers the Mac, and one that
  # greets the user is ordinary on a managed one. ~/.zprofile is the file of
  # that set a test can legitimately write, and it reaches the probe the same
  # way /etc/zshrc does. The damage is specific: the profile sits at the FRONT
  # of PATH, so a banner lands exactly on the field the reachability check
  # reads, and the user is warned about an install that is perfectly fine.
  # shellcheck disable=SC2016  # zsh expands these when it sources the file, not this shell
  printf '%s\n' \
    'print -r -- "Notice: this Mac is managed by somebody else."' \
    'export PATH="$HOME/.nix-profile/bin:$PATH"' >"$home/.zprofile"

  HOME="$home" install_report_login_path >/dev/null 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    skip "login-shell probe (no usable zsh to probe with)"
    return 0
  fi

  output=$(HOME="$home" install_report "    " /stand-in/prefix)

  assert_contains "$output" "Checked: a new login shell does find them" \
    "the profile is on the login PATH, so the report should say so"
  assert_not_contains "$output" "WARNING" \
    "a banner a startup file printed was read as part of PATH"

  pass "report: what a startup file prints is not mistaken for the login PATH"
}

test_a_path_fix_in_zshrc_local_is_seen_as_reachable() {
  local home output status=0

  home=$(install_report_fixture_home)

  # The repair README gives a user who cannot touch /etc/zshrc. ~/.zshrc.local
  # is his file, ~/.zshrc includes it at lib.mkOrder 1500, and once it is there
  # every new terminal really does find the tools. A check that could not see
  # it would go on telling him they are unreachable and go on blaming whoever
  # administers his Mac - permanently, and wrongly.
  # shellcheck disable=SC2016  # zsh expands this when it sources the file, not this shell
  printf '%s\n' 'export PATH="$HOME/.nix-profile/bin:$PATH"' >"$home/.zshrc.local"

  HOME="$home" install_report_login_path >/dev/null 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    skip "login-shell probe (no usable zsh to probe with)"
    return 0
  fi

  output=$(HOME="$home" install_report "    " /stand-in/prefix)

  assert_contains "$output" "Checked: a new login shell does find them" \
    "a PATH fixed in ~/.zshrc.local does reach a new terminal, so say so"
  assert_not_contains "$output" "WARNING" \
    "a user who has already fixed his PATH must not be warned about it"

  pass "report: a PATH fix in ~/.zshrc.local counts as reachable"
}

test_a_zshrc_local_that_stops_the_probe_reads_as_unverified() {
  local home output

  home=$(install_report_fixture_home)

  # The cost of sourcing it: ~/.zshrc.local is a file the user wrote, so it can
  # exit early, fail, or be broken outright. Whatever it does, the one answer
  # this check must never give is a confident one.
  printf '%s\n' 'exit 1' >"$home/.zshrc.local"

  output=$(HOME="$home" install_report "    " /stand-in/prefix)

  assert_contains "$output" "Not checked" \
    "a probe the user's own file stopped must read as unverified"
  assert_not_contains "$output" "Checked: a new login shell does find them" \
    "a probe that never answered must never claim the tools are reachable"

  pass "report: a ~/.zshrc.local that stops the probe reads as unverified, not fine"
}

# --- the one property no stub can prove ---------------------------------------

test_the_probe_does_not_inherit_this_process_path() {
  local home sentinel path status=0

  home=$(install_report_fixture_home)

  # bootstrap.sh reaches the report with nix, and everything else the profile
  # carries, already on its own PATH - step 1 sourced it in. A probe that
  # inherited that would agree the tools are reachable no matter what a fresh
  # terminal would really get, which is the one way this check could be
  # silently wrong in the direction of "all good".
  #
  # The sentinel is deliberately NOT under the fixture home. A startup file can
  # rebuild a HOME-relative path without inheriting anything: /etc/zshrc's
  # Determinate block sources nix-daemon.sh, which sets NIX_LINK=$HOME/.nix-profile
  # and prepends $NIX_LINK/bin, and the probe passes HOME through on purpose. So
  # "$home/.nix-profile/bin" in the answer proves nothing, and asserting on it
  # fails on every Determinate Mac and in CI, where the nix-installer-action
  # edits the shell profiles. No startup file can name this directory, so it
  # can only appear in the answer by having been inherited.
  sentinel="$(dirname "$home")/sentinel-bin"
  mkdir -p "$sentinel"

  path=$(HOME="$home" PATH="$sentinel:$PATH" install_report_login_path) \
    || status=$?

  if [ "$status" != 0 ]; then
    skip "login-shell probe (no usable zsh to probe with)"
    return 0
  fi

  case ":$path:" in
    *:"$sentinel":*)
      fail "the reachability probe inherited the calling process's PATH" ;;
  esac

  pass "report: the reachability probe answers for a fresh shell, not for this one"
}

test_the_report_says_what_was_installed_and_where
test_the_report_points_at_the_homebrew_path_line_too
test_an_empty_profile_is_reported_as_a_broken_install
test_only_a_profile_proven_empty_fails_the_run
test_the_report_mentions_the_zshrc_backup_only_when_there_is_one
test_an_unreachable_profile_is_a_loud_warning_naming_etc_zshrc
test_a_reachable_profile_produces_no_warning
test_an_unanswerable_check_is_never_reported_as_fine
test_a_startup_file_that_prints_is_not_read_as_path
test_a_path_fix_in_zshrc_local_is_seen_as_reachable
test_a_zshrc_local_that_stops_the_probe_reads_as_unverified
test_the_probe_does_not_inherit_this_process_path

test_summary
