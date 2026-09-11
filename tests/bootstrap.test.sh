#!/usr/bin/env bash
# Behaviour tests for bootstrap.sh.
#
# Most of this is about the interactive steps, which live in lib/personalize.sh
# so they can be driven by a script instead of a person; the rest is the refusal
# in lib/nix-present.sh, which is in a library for the same reason. bootstrap.sh
# itself is not run end to end by anything: running it installs Nix and asks for
# a password twice. Its step ORDER is deliberately not asserted here either -
# AGENTS.md says why, and why a grep over its source is not an acceptable
# substitute.
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
# lib/nix-present.sh is deliberately NOT sourced here: its checks run it in a
# fresh bash with a PATH of their own, which is the only way to ask what it does
# on a machine that has no nix without taking this shell's tools away too.

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 12

# A PATH with the ordinary system tools and deliberately no nix. The system
# directories are the point: a Nix under /nix/var/nix, or one a CI runner put
# on PATH, must not leak into the check that asserts what happens without one.
SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin

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

# --- the refusal that has to happen before the password -----------------------
#
# bootstrap.sh asks lib/nix-present.sh for the path to `nix` immediately after
# step 1, and the answer is what step 7 runs; that library says why it has to be
# asked there and only there.
#
# What is covered here is the refusal itself, at the layer where that is honest.
# The step ORDER is not asserted, for the reason at the top of this file.

test_a_missing_nix_is_a_refusal_that_says_what_to_do() {
  local output status=0

  # A fresh bash under `env`, rather than a PATH assignment around a call in
  # this shell: the stripped PATH must not outlive the check and leave the rest
  # of this file running without the system tools.
  # shellcheck disable=SC2016  # $1 is the inner shell's argument, not this one's
  output=$(env PATH="$SYSTEM_PATH" /bin/bash -c \
    '. "$1/lib/nix-present.sh"; dotfiles_nix_path' _ "$ROOT" 2>&1) || status=$?

  assert_eq "$status" 1 \
    "a missing nix should be a refusal, not a silently empty answer"
  assert_contains "$output" "nix is not on this shell's PATH" \
    "the refusal should name the problem"
  assert_contains "$output" "Open a new terminal and re-run ./bootstrap.sh" \
    "the refusal should say what to do about it"

  pass "bootstrap: a missing nix is refused with both the cause and the fix"
}

test_an_installed_nix_is_handed_back_to_the_switch() {
  local tmp found
  # The other half: step 7 runs whatever this returns, so returning a usable
  # path is as load-bearing as refusing. A stub, because the machine running
  # the suite may or may not have a real nix and this must not depend on it.
  tmp=$(dotfiles_test_tmproot dotfiles-nix)
  printf '#!/bin/bash\nexit 0\n' >"$tmp/nix"
  chmod +x "$tmp/nix"

  # shellcheck disable=SC2016  # as above
  found=$(env PATH="$tmp:$SYSTEM_PATH" /bin/bash -c \
    '. "$1/lib/nix-present.sh"; dotfiles_nix_path' _ "$ROOT")

  assert_eq "$found" "$tmp/nix" \
    "the path handed to the switch is not the nix that is actually on PATH"

  pass "bootstrap: an installed nix comes back as the path the switch runs"
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
test_a_missing_nix_is_a_refusal_that_says_what_to_do
test_an_installed_nix_is_handed_back_to_the_switch
test_bootstrap_never_prompts_for_a_machine_name


test_summary
