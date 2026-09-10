#!/usr/bin/env bash
# End-to-end tests for rebuild.sh, run as a script.
#
# This file exists because the rest of the suite could not have caught the
# failure that produced it. Everything else here tests a library function, an
# evaluated option or a built artifact; nothing ran either entry point as a
# script, so the whole of rebuild.sh - what it checks, in what order, and what
# the user is left looking at when it stops - was covered by nothing.
#
# What went wrong: bootstrap.sh installs Nix and sources the Determinate
# profile script into its OWN process, so the terminal it was launched from
# still has no `nix`. Running ./rebuild.sh in that same terminal produced
#
#   ./rebuild.sh: line 39: nix: command not found
#
# followed by seven friendly lines of git-identity advice, and an exit status
# an interactive shell never shows. Nothing was installed and nothing said so.
# bootstrap.sh already guarded its own switch against exactly this and
# explained it in as many words; rebuild.sh did not.
#
# The switch is stubbed, never run. `nix` here is a fixture script that records
# its arguments and exits with whatever status the test asks for, so every
# check below runs in milliseconds, needs no Nix, activates nothing, and works
# on a machine that has never bootstrapped. HOME is a temp directory
# throughout; nothing here touches the real home or the repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/flake-settings.sh
. "$ROOT/lib/flake-settings.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 6

# A PATH with the ordinary system tools and deliberately no nix. The system
# directories are the point: a Nix under /nix/var/nix, or one a CI runner put
# on PATH, must not leak into the check that asserts what happens without one.
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Build a fixture and leave it in FIXTURE_TMP / FIXTURE_REPO / FIXTURE_HOME.
#
# Only rebuild.sh, lib/*.sh and flake.nix are copied, because that is all
# rebuild.sh reads. Nothing builds the flake - the switch is stubbed - so the
# rest of the tree would be dead weight, and copying the repository wholesale
# would drag .git along with it.
#
# $1 is the username to configure. The home directory is written afterwards by
# the caller, or left as the repo's own value when the point of the test is a
# mismatch.
rebuild_fixture() {
  local user=$1
  FIXTURE_TMP=$(dotfiles_test_tmproot dotfiles-rebuild)
  FIXTURE_REPO="$FIXTURE_TMP/repo"
  FIXTURE_HOME="$FIXTURE_TMP/home"
  mkdir -p "$FIXTURE_REPO/lib" "$FIXTURE_HOME" "$FIXTURE_TMP/bin"
  cp "$ROOT/rebuild.sh" "$FIXTURE_REPO/rebuild.sh"
  cp "$ROOT"/lib/*.sh "$FIXTURE_REPO/lib/"
  cp "$ROOT/flake.nix" "$FIXTURE_REPO/flake.nix"

  # Through the repo's own writer, so a fixture cannot drift from the format
  # the real parser accepts.
  flake_settings_set_user "$FIXTURE_REPO/flake.nix" "$user" \
    || fail "could not write the fixture username"
}

# Point the fixture at the fixture home, which is what makes it describe "this
# machine" for the checks that are not about a mismatch.
rebuild_fixture_matches_this_machine() {
  flake_settings_set_home_directory "$FIXTURE_REPO/flake.nix" "$FIXTURE_HOME" \
    || fail "could not point the fixture at the fixture home"
}

# A `nix` that records how it was called and exits with $1.
rebuild_stub_nix() {
  local status=$1
  cat >"$FIXTURE_TMP/bin/nix" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$FIXTURE_TMP/nix-invocations"
exit $status
STUB
  chmod +x "$FIXTURE_TMP/bin/nix"
  : >"$FIXTURE_TMP/nix-invocations"
}

# Run rebuild.sh against the fixture with $1 as PATH, leaving the combined
# output in REBUILD_OUTPUT and the exit status in REBUILD_STATUS.
#
# Both come back through variables rather than through stdout, because a
# `$(rebuild_run ...)` would run the whole thing in a subshell and the status -
# which is half of what these checks are about - would never reach the caller.
#
# XDG_CONFIG_HOME and the system git config are dropped so the identity report
# answers for the fixture home and not for whoever is running the suite.
REBUILD_STATUS=0
REBUILD_OUTPUT=""
rebuild_run() {
  local path=$1
  REBUILD_STATUS=0
  env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    HOME="$FIXTURE_HOME" PATH="$path" GIT_CONFIG_NOSYSTEM=1 \
    /bin/bash "$FIXTURE_REPO/rebuild.sh" >"$FIXTURE_TMP/output" 2>&1 || REBUILD_STATUS=$?
  REBUILD_OUTPUT=$(cat "$FIXTURE_TMP/output")
}

# --- the guard bootstrap.sh already had ---------------------------------------

test_refuses_when_nix_is_not_on_this_shells_path() {
  local output
  rebuild_fixture "$(whoami)"
  rebuild_fixture_matches_this_machine

  rebuild_run "$SYSTEM_PATH"
  output=$REBUILD_OUTPUT

  # 1, not 127: a refusal this script chose, rather than a bare "command not
  # found" from bash with seven lines of unrelated advice under it.
  assert_eq "$REBUILD_STATUS" 1 \
    "a missing nix should be a refusal rebuild.sh chose, not a bash error"
  assert_contains "$output" "nix is not on this shell's PATH" \
    "the refusal should name the problem"
  assert_contains "$output" "Open a new terminal" \
    "the refusal should say what to do about it, as bootstrap.sh does"
  assert_not_contains "$output" "Heads up" \
    "a run that never reached the switch should not hand out git advice"

  # And it must refuse before it writes: ~/.dotfiles is the name every later
  # step resolves through, and a run that cannot proceed has no business
  # repointing it.
  [ ! -e "$FIXTURE_HOME/.dotfiles" ] \
    || fail "rebuild.sh created ~/.dotfiles before refusing over a missing nix"

  pass "rebuild: a missing nix is a refusal that says to open a new terminal"
}

# --- refuse before repointing ~/.dotfiles -------------------------------------

test_refuses_before_repointing_dotfiles_on_a_machine_mismatch() {
  local other output
  # A fresh clone of this public repository is configured for whoever committed
  # last, which is the state this check describes.
  rebuild_fixture somebody-elses-account
  rebuild_stub_nix 0

  # The machine already uses another dotfiles repository through ~/.dotfiles -
  # the ordinary state of a Mac that carries a personal config as well.
  other="$FIXTURE_TMP/other-dotfiles"
  mkdir -p "$other"
  ln -sfn "$other" "$FIXTURE_HOME/.dotfiles"

  rebuild_run "$FIXTURE_TMP/bin:$SYSTEM_PATH"
  output=$REBUILD_OUTPUT

  assert_eq "$REBUILD_STATUS" 1 "a configuration built for another account should be refused"
  assert_contains "$output" "somebody-elses-account" \
    "the refusal should name the configured account"

  # The point of the check. Leaving ~/.dotfiles pointing at a configuration
  # this script has just declared unusable breaks home.nix's editor and
  # terminal symlinks and the rollback commands HOW-TO.md gives, and the
  # refusal says nothing about having done it.
  assert_eq "$(readlink "$FIXTURE_HOME/.dotfiles")" "$other" \
    "rebuild.sh repointed ~/.dotfiles at a configuration it then refused"

  [ ! -s "$FIXTURE_TMP/nix-invocations" ] \
    || fail "rebuild.sh ran the switch despite refusing"

  pass "rebuild: a machine mismatch is refused before ~/.dotfiles is repointed"
}

# --- the last thing on the screen is the truth about the run ------------------

test_a_failed_switch_says_so_last_and_suppresses_the_identity_report() {
  local output last
  rebuild_fixture "$(whoami)"
  rebuild_fixture_matches_this_machine
  rebuild_stub_nix 7

  rebuild_run "$FIXTURE_TMP/bin:$SYSTEM_PATH"
  output=$REBUILD_OUTPUT
  last=$(printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | tail -n1)

  assert_eq "$REBUILD_STATUS" 7 "the switch's own exit status should be re-raised"
  assert_contains "$output" "the rebuild did not complete" \
    "a failed switch should say that it failed"
  # And it must not claim more than it can know. The switch writes as it goes,
  # so a failure part of the way through can leave the home directory half
  # updated; telling the user nothing changed would be the same untruth as the
  # one this script exists to stop printing, with the sign reversed.
  assert_contains "$output" "may already have been applied" \
    "a failed switch should say the home directory may be partly updated"

  # The identity report is friendly advice. Printed after a failure it put
  # seven reassuring lines underneath an error, which is how a run that changed
  # nothing comes to read like a run that worked.
  assert_not_contains "$output" "Heads up" \
    "the identity report should not print after a failed switch"
  # The closing verdict is the same kind of advice, and it would be answering
  # for a switch that never finished.
  assert_not_contains "$output" "command-line tools" \
    "the closing verdict should not print after a failed switch"
  assert_contains "$last" "covers the ones that come up" \
    "the failure, not advice, should be the last thing on the screen"

  pass "rebuild: a failed switch reports the failure last and says nothing else"
}

test_a_successful_switch_runs_the_identity_report() {
  local output invocation expected
  rebuild_fixture "$(whoami)"
  rebuild_fixture_matches_this_machine
  rebuild_stub_nix 0

  rebuild_run "$FIXTURE_TMP/bin:$SYSTEM_PATH"
  output=$REBUILD_OUTPUT
  invocation=$(cat "$FIXTURE_TMP/nix-invocations")
  expected="switch --flake $FIXTURE_HOME/.dotfiles#$(flake_settings_config_name "$FIXTURE_REPO/flake.nix")"

  assert_eq "$REBUILD_STATUS" 0 "a successful switch should exit 0"

  # The fixture home has no identity anywhere, so the report has something to
  # say - which is the half of the behaviour the failure case must not have.
  assert_contains "$output" "Heads up" \
    "the identity report should still run after a successful switch"
  assert_not_contains "$output" "the rebuild did not complete" \
    "a successful switch must not claim it failed"

  # And the switch was handed the configuration this repo declares, through
  # ~/.dotfiles rather than through the clone's own path.
  assert_contains "$invocation" "$expected" \
    "the switch should build ~/.dotfiles#<user>@<system>"

  pass "rebuild: a successful switch exits 0 and still reports the git identity"
}

# --- what a run that worked leaves the user knowing ---------------------------
#
# The closing report tells a user to come here - "Open a new terminal, then run
# ./rebuild.sh from there" is what it prints when nothing was installed - so
# this is the script that has to answer the two questions he arrived with. It
# is not the full report: a rebuild runs often, and a wall of text every time
# teaches people to stop reading it.

test_a_successful_rebuild_says_what_is_there_and_whether_a_shell_finds_it() {
  local output
  rebuild_fixture "$(whoami)"
  rebuild_fixture_matches_this_machine
  rebuild_stub_nix 0

  # A profile the switch could have left, and a login shell that will find it.
  # ~/.zprofile is one of the files the probe sources, so this holds whatever
  # /etc/zshrc on the machine running the suite happens to say.
  mkdir -p "$FIXTURE_HOME/.nix-profile/bin"
  touch "$FIXTURE_HOME/.nix-profile/bin/rg" "$FIXTURE_HOME/.nix-profile/bin/fd"
  # shellcheck disable=SC2016  # zsh expands these when it sources the file, not this shell
  printf '%s\n' 'export PATH="$HOME/.nix-profile/bin:$PATH"' >"$FIXTURE_HOME/.zprofile"

  rebuild_run "$FIXTURE_TMP/bin:$SYSTEM_PATH"
  output=$REBUILD_OUTPUT

  assert_eq "$REBUILD_STATUS" 0 "a successful switch should exit 0"
  assert_contains "$output" "holds 2 command-line tools" \
    "a rebuild should say what the profile carries now"

  if command -v zsh >/dev/null 2>&1; then
    assert_contains "$output" "Checked: a new login shell does find them" \
      "a reachable profile should be confirmed, which is what the user came for"
  else
    # No zsh to probe with is the third state, and it has to read as
    # unverified rather than as silence or as fine.
    assert_contains "$output" "Not checked" \
      "a check that could not run must say so rather than say nothing"
  fi

  pass "rebuild: a successful run says what is installed and whether a shell finds it"
}

test_a_switch_that_leaves_an_empty_profile_is_not_reported_as_fine() {
  local output
  rebuild_fixture "$(whoami)"
  rebuild_fixture_matches_this_machine
  rebuild_stub_nix 0

  # Exactly the state a user is sent here to recover from: the switch reports
  # success and the profile is still empty. Nothing else in the run produces an
  # error, so saying nothing here reads as "it worked".
  rebuild_run "$FIXTURE_TMP/bin:$SYSTEM_PATH"
  output=$REBUILD_OUTPUT

  assert_eq "$REBUILD_STATUS" 0 "the switch's own status is what rebuild.sh re-raises"
  assert_contains "$output" "WARNING: ~/.nix-profile/bin is empty or missing" \
    "an empty profile after a successful switch must not pass in silence"
  assert_not_contains "$output" "Checked: a new login shell does find them" \
    "an empty profile must never be confirmed as reachable"

  pass "rebuild: a switch that leaves an empty profile is not reported as fine"
}

test_refuses_when_nix_is_not_on_this_shells_path
test_refuses_before_repointing_dotfiles_on_a_machine_mismatch
test_a_failed_switch_says_so_last_and_suppresses_the_identity_report
test_a_successful_switch_runs_the_identity_report
test_a_successful_rebuild_says_what_is_there_and_whether_a_shell_finds_it
test_a_switch_that_leaves_an_empty_profile_is_not_reported_as_fine

test_summary
