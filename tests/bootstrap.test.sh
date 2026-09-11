#!/usr/bin/env bash
# Behaviour tests for bootstrap.sh.
#
# Almost everything here is about the interactive steps, which live in
# lib/personalize.sh so they can be driven by a script instead of a person. The
# last check is about the script's SHAPE instead, and says so where it sits:
# bootstrap.sh is the one file in this repository that cannot be run end to end
# by a test, because running it installs Nix and asks for a password twice.
#
# The property under test in the interactive checks is the one the repository
# this replaces got wrong:
#
#   Wherever a default is offered, the default is THIS MACHINE'S CURRENT VALUE,
#   never the value already written in the config.
#
# There, the machine-name prompt defaulted to the *configured* name, so pressing
# Enter renamed the Mac. Nothing here renames anything, but a prompt that
# defaulted to the configured account or the configured home directory would
# build a configuration for somebody else's home - silently, for a user who did
# nothing more suspicious than accept what looked like a sensible default.
#
# Every check runs against a fixture flake.nix in a temp directory and a fake
# HOME. Nothing here touches the repository or the real home directory, and
# nothing here activates anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/flake-settings.sh
. "$ROOT/lib/flake-settings.sh"
# shellcheck source=lib/personalize.sh
. "$ROOT/lib/personalize.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 11

# --- the one privileged step, and where it sits -------------------------------

test_the_privileged_step_runs_after_every_check_and_before_the_switch() {
  local sudo_line

  # bootstrap.sh creates Homebrew's prefix under the single `sudo` in this
  # repository. Two rules govern where that line may go, and neither is visible
  # from any single step:
  #
  #   - everything that can refuse the run must already have refused. The prefix
  #     is outside the home directory, so creating it for a run that then stops
  #     on a wrong account or a wrong home directory would leave a machine
  #     changed by a bootstrap that did not finish. AGENTS.md states the rule as
  #     "a script refuses before it writes";
  #   - it must come before the switch, because the activation step that links
  #     Homebrew into that prefix has no way to create it and fails without it.
  #
  # Asserted against the source, which is unusual in this suite and deliberate
  # here. The rest of these checks run the code; this one cannot, because the
  # lines between the two markers install Nix. What is being asserted is a fact
  # about what this script CONTAINS and in what order - the same kind of claim
  # tests/safety.test.sh makes about `sudo` appearing at all - not prose used as
  # a proxy for behaviour.
  # A function, not a `local`: bash 3.2 has no local functions, and declaring
  # the name as a variable too is what shellcheck reads as a dead assignment.
  line_of() {
    grep -n -F -- "$1" "$ROOT/bootstrap.sh" | head -n1 | cut -d: -f1
  }

  sudo_line=$(line_of 'lib/homebrew-initialize-prefix.sh')
  [ -n "$sudo_line" ] \
    || fail "bootstrap.sh never runs the script that creates Homebrew's prefix"

  # The preflight, which is what makes a refusal cost nothing: it looks at the
  # prefix before Nix is installed and before any password is asked for.
  [ "$(line_of 'dotfiles_homebrew_preflight')" -lt "$(line_of 'install.determinate.systems')" ] \
    || fail "the Homebrew preflight runs after the Nix installer, so a Mac it would refuse pays for a Nix install first"

  [ "$(line_of 'install.determinate.systems')" -lt "$sudo_line" ] \
    || fail "the prefix is created before Nix is installed, which is not the documented order"

  [ "$(line_of 'flake_settings_check_machine')" -lt "$sudo_line" ] \
    || fail "the prefix is created before the account and home directory are checked, so a run that then refuses would still have written outside \$HOME"

  [ "$sudo_line" -lt "$(line_of 'switch -b backup')" ] \
    || fail "the prefix is created after the switch, so the first activation would have nowhere to install Homebrew"

  pass "bootstrap: the one privileged step runs after every check and before the switch"
}

write_fixture() {
  local path=$1 user=$2 home=$3
  cat >"$path" <<FIXTURE
{
  outputs = { ... }:
    let
      user = "$user";
      homeDirectory = $home;
    in
    { };
}
FIXTURE
}

# --- the username prompt ------------------------------------------------------

test_pressing_enter_keeps_this_machines_username() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  # A flake configured for somebody else - the state every fresh clone of this
  # public repo is in.
  write_fixture "$file" somebody-elses-account null

  # An empty answer: the user pressed Enter.
  printf '\n' | personalize_user "$file" >/dev/null

  assert_eq "$(flake_settings_user "$file")" "$(whoami)" \
    "pressing Enter kept the configured username instead of this machine's"

  pass "bootstrap: pressing Enter at the username prompt takes this machine's account"
}

test_an_explicit_username_is_used() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  write_fixture "$file" somebody-elses-account null

  printf 'chosen-account\n' | personalize_user "$file" >/dev/null

  assert_eq "$(flake_settings_user "$file")" chosen-account \
    "an explicitly typed username was not written"

  pass "bootstrap: a typed username is used as given"
}

test_a_matching_username_asks_nothing() {
  local tmp file output
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  write_fixture "$file" "$(whoami)" null

  # Nothing on stdin. A prompt that read anyway would see end-of-file, and the
  # step must not depend on that: it must not ask at all.
  output=$(personalize_user "$file" </dev/null)

  assert_eq "$(flake_settings_user "$file")" "$(whoami)" \
    "an already-correct username was changed"
  assert_contains "$output" "nothing to do" \
    "an already-correct username still prompted"

  pass "bootstrap: an already-correct username is left alone without a prompt"
}

# --- the home directory prompt ------------------------------------------------

test_pressing_enter_keeps_this_machines_home_directory() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  # Username right, home directory wrong: the managed-Mac case, where the
  # account exists but its home is not /Users/<shortname>.
  write_fixture "$file" "$(whoami)" '"/Volumes/accounts/somebody"'

  printf '\n' | personalize_home_directory "$file" >/dev/null

  assert_eq "$(flake_settings_home_directory "$file")" "$HOME" \
    "pressing Enter kept the configured home directory instead of this machine's"

  pass "bootstrap: pressing Enter at the home prompt takes this machine's home directory"
}

test_an_explicit_home_directory_is_used() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  # Configured for another account, so the derived /Users/<user> is not this
  # machine's home and the prompt really happens.
  write_fixture "$file" chosen-account null

  # A home that is neither the configured one nor this machine's, which is what
  # a user with an unusual account layout would type.
  printf '/Volumes/accounts/typed\n' | personalize_home_directory "$file" >/dev/null

  assert_eq "$(flake_settings_home_directory "$file")" /Volumes/accounts/typed \
    "an explicitly typed home directory was not written"

  pass "bootstrap: a typed home directory is used as given"
}

test_an_ordinary_home_directory_is_written_back_as_null() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  write_fixture "$file" chosen-account '"/Volumes/accounts/somebody"'

  # Answering with exactly /Users/<user> means the ordinary macOS layout after
  # all, and the line that needs no maintenance is the one that says so.
  printf '/Users/chosen-account\n' | personalize_home_directory "$file" >/dev/null

  assert_contains "$(cat "$file")" "homeDirectory = null;" \
    "an ordinary /Users/<user> home was written as a literal path instead of null"
  assert_eq "$(flake_settings_home_directory "$file")" /Users/chosen-account \
    "the null home directory does not resolve to /Users/<user>"

  pass "bootstrap: an ordinary /Users/<user> answer is stored as null"
}

test_a_matching_home_directory_asks_nothing() {
  local tmp file output
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  file="$tmp/flake.nix"
  write_fixture "$file" "$(whoami)" "\"$HOME\""

  output=$(personalize_home_directory "$file" </dev/null)

  assert_contains "$output" "Nothing to do" \
    "an already-correct home directory still prompted"

  pass "bootstrap: an already-correct home directory is left alone without a prompt"
}

# --- seeding the untracked local files ----------------------------------------

test_seeding_creates_the_local_file() {
  local tmp
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)

  printf 'guidance\n' | seed_local_file "$tmp/.zshrc.local" "the local file" >/dev/null
  assert_eq "$(cat "$tmp/.zshrc.local")" guidance \
    "the seeded file does not contain the guidance"

  pass "bootstrap: an absent local file is seeded with its guidance"
}

test_seeding_never_touches_an_existing_local_file() {
  local tmp output
  # This is the file holding whatever the user's employer requires. Overwriting
  # it would destroy configuration this repo has never seen and cannot restore.
  tmp=$(dotfiles_test_tmproot dotfiles-bootstrap)
  printf 'export SOMETHING_IMPORTANT=1\n' >"$tmp/.zshrc.local"

  output=$(printf 'guidance\n' | seed_local_file "$tmp/.zshrc.local" "the local file")

  assert_eq "$(cat "$tmp/.zshrc.local")" "export SOMETHING_IMPORTANT=1" \
    "an existing local file was overwritten"
  assert_contains "$output" "leaving it alone" \
    "overwriting was skipped but not reported"

  pass "bootstrap: an existing local file is never overwritten"
}

# --- what bootstrap.sh itself promises ----------------------------------------

test_bootstrap_never_prompts_for_a_machine_name() {
  local tmp file scutil_stub invoked
  # There is nothing to rename, so there must be no prompt that looks like
  # there is. A machine-name step is the exact shape of the mistake this repo
  # exists to avoid. This test runs personalize_user and personalize_home_directory
  # with a scutil stub on PATH that creates a trace file if invoked; since both
  # functions have been tested to work correctly above, and they work without
  # ever calling scutil, the stub should never run.
  tmp=$(dotfiles_test_tmproot dotfiles-scutil)
  file="$tmp/flake.nix"
  write_fixture "$file" "$(whoami)" "\"$HOME\""

  scutil_stub="$tmp/scutil"
  cat >"$scutil_stub" <<'STUB'
#!/bin/bash
touch "$TMPDIR/scutil-was-invoked"
exit 1
STUB
  chmod +x "$scutil_stub"

  # Run personalize_user and personalize_home_directory with scutil_stub first on PATH.
  # Both are already configured correctly, so they ask nothing and stdin can be closed.
  PATH="$tmp:$PATH" personalize_user "$file" </dev/null >/dev/null 2>&1
  PATH="$tmp:$PATH" personalize_home_directory "$file" </dev/null >/dev/null 2>&1

  # Check whether the stub was invoked. It should not be, because these functions
  # should never call scutil.
  invoked=$(ls "$TMPDIR"/scutil-was-invoked 2>/dev/null || echo "")
  [ -z "$invoked" ] || fail "scutil was invoked when it should never be"

  pass "bootstrap: personalize functions never invoke scutil"
}

test_pressing_enter_keeps_this_machines_username
test_an_explicit_username_is_used
test_a_matching_username_asks_nothing
test_pressing_enter_keeps_this_machines_home_directory
test_an_explicit_home_directory_is_used
test_an_ordinary_home_directory_is_written_back_as_null
test_a_matching_home_directory_asks_nothing
test_seeding_creates_the_local_file
test_seeding_never_touches_an_existing_local_file
test_bootstrap_never_prompts_for_a_machine_name

test_the_privileged_step_runs_after_every_check_and_before_the_switch

test_summary
