#!/usr/bin/env bash
# Behaviour tests for lib/flake-settings.sh - the code that reads and rewrites
# the two adjustable lines in flake.nix, and that decides whether this
# configuration describes the machine it is about to be built on.
#
# It is exercised against real flake.nix copies in a temp directory and, for
# the parsing side, against the repository's own flake.nix. Nothing here writes
# to the repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/flake-settings.sh
. "$ROOT/lib/flake-settings.sh"

dotfiles_test_parse_args "$@"

# A minimal file with the same two lines flake.nix carries. Using a fixture
# rather than a copy of flake.nix keeps a failure here pointing at the parser
# instead of at whatever else the real file happens to contain - and the round
# trip against the real file is a separate test below.
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

test_reads_the_repositorys_own_settings() {
  local user home
  user=$(flake_settings_user "$ROOT/flake.nix") \
    || fail "could not read the user from the repository's flake.nix"
  [ -n "$user" ] || fail "the repository's flake.nix parsed to an empty user"

  home=$(flake_settings_home_directory "$ROOT/flake.nix") \
    || fail "could not read the home directory from the repository's flake.nix"
  case $home in
    /*) : ;;
    *) fail "the repository's flake.nix parsed to a relative home directory: $home" ;;
  esac

  pass "settings: the repository's own flake.nix parses (user \"$user\", home \"$home\")"
}

test_null_home_directory_derives_from_the_user() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  write_fixture "$file" someone null

  assert_eq "$(flake_settings_home_directory "$file")" "/Users/someone" \
    "a null homeDirectory should derive /Users/<user>"

  pass "settings: homeDirectory = null means /Users/<user>"
}

test_explicit_home_directory_is_used_verbatim() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  # The shape a managed Mac actually produces: a home that is not
  # /Users/<shortname>. This is the case home.nix must not assume away.
  write_fixture "$file" someone '"/Volumes/accounts/someone"'

  assert_eq "$(flake_settings_home_directory "$file")" "/Volumes/accounts/someone" \
    "an explicit homeDirectory should be used as written"

  pass "settings: an explicit homeDirectory overrides /Users/<user>"
}

test_writing_settings_round_trips() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  write_fixture "$file" someone null

  flake_settings_set_user "$file" other || fail "could not write the user"
  assert_eq "$(flake_settings_user "$file")" other "the written user did not read back"

  flake_settings_set_home_directory "$file" /Volumes/accounts/other \
    || fail "could not write the home directory"
  assert_eq "$(flake_settings_home_directory "$file")" /Volumes/accounts/other \
    "the written home directory did not read back"

  # And back to null, which is what bootstrap.sh writes when the home turns out
  # to be the ordinary /Users/<user> after all.
  flake_settings_set_home_directory "$file" null || fail "could not write null"
  assert_eq "$(flake_settings_home_directory "$file")" /Users/other \
    "writing null did not restore the derived home directory"

  pass "settings: user and homeDirectory round-trip through a write and a read"
}

test_writing_preserves_the_rest_of_the_file() {
  local tmp file before after
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  write_fixture "$file" someone null
  before=$(grep -vE 'user = |homeDirectory = ' "$file")

  flake_settings_set_user "$file" other
  flake_settings_set_home_directory "$file" /Volumes/accounts/other
  after=$(grep -vE 'user = |homeDirectory = ' "$file")

  assert_eq "$after" "$before" "rewriting the two settings changed other lines"

  pass "settings: a write touches only the two lines it owns"
}

test_the_real_flake_takes_a_write() {
  local tmp file
  # The parser is only useful if it works on the file bootstrap.sh will really
  # rewrite, whatever else that file grows. Copied first: this test must never
  # write to the repository.
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  cp "$ROOT/flake.nix" "$file"

  flake_settings_set_user "$file" round-trip-user \
    || fail "could not rewrite the user in a copy of the real flake.nix"
  assert_eq "$(flake_settings_user "$file")" round-trip-user \
    "the real flake.nix did not take a user rewrite"

  flake_settings_set_home_directory "$file" /Volumes/accounts/round-trip \
    || fail "could not rewrite the home directory in a copy of the real flake.nix"
  assert_eq "$(flake_settings_home_directory "$file")" /Volumes/accounts/round-trip \
    "the real flake.nix did not take a home directory rewrite"

  pass "settings: the repository's real flake.nix takes both rewrites"
}

test_a_value_that_cannot_be_written_is_refused() {
  local tmp file before
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  write_fixture "$file" someone null
  before=$(cat "$file")

  # Refusing is the honest answer. A quote or a backslash cannot survive the
  # round trip into a Nix string literal, and writing it anyway would produce a
  # flake.nix that does not parse - a much worse failure, and one that happens
  # later, when the user is mid-bootstrap.
  ! flake_settings_set_user "$file" 'bad"name' 2>/dev/null \
    || fail "a username containing a quote was written into flake.nix"
  ! flake_settings_set_home_directory "$file" 'relative/path' 2>/dev/null \
    || fail "a relative home directory was written into flake.nix"
  ! flake_settings_set_home_directory "$file" '/bad"path' 2>/dev/null \
    || fail "a home directory containing a quote was written into flake.nix"

  assert_eq "$(cat "$file")" "$before" "a refused write still modified the file"

  pass "settings: an unwritable value is refused, and the file is left untouched"
}

test_a_missing_line_is_reported_not_guessed() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"
  printf '{ }\n' >"$file"

  ! flake_settings_user "$file" 2>/dev/null \
    || fail "a flake.nix with no user line still produced a user"
  ! flake_settings_home_directory "$file" 2>/dev/null \
    || fail "a flake.nix with no homeDirectory line still produced a home directory"
  ! flake_settings_set_user "$file" someone 2>/dev/null \
    || fail "a flake.nix with no user line still took a write"

  pass "settings: a missing setting line stops the script instead of being guessed"
}

test_the_architecture_is_read_off_the_machine() {
  local system expected
  system=$(flake_settings_system) || fail "could not determine this machine's system"
  case "$(uname -m)" in
    arm64) expected=aarch64-darwin ;;
    x86_64) expected=x86_64-darwin ;;
    *) skip "architecture detection (unrecognized machine $(uname -m))"; return 0 ;;
  esac
  assert_eq "$system" "$expected" "the detected system does not match this machine"

  # Both are real flake outputs, so an Intel Mac is not a second-class citizen
  # that needs an edit before it can build.
  if ! command -v nix >/dev/null 2>&1; then
    skip "both architectures are real flake outputs (nix not found)"
  else
    local names
    names=$(nix eval --raw "$ROOT#homeConfigurations" \
      --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' 2>/dev/null) \
      || fail "could not list the flake's homeConfigurations"
    assert_contains "$names" "@aarch64-darwin" "no aarch64-darwin configuration is exposed"
    assert_contains "$names" "@x86_64-darwin" "no x86_64-darwin configuration is exposed"
    pass "settings: both aarch64-darwin and x86_64-darwin are real flake outputs"
  fi

  pass "settings: the system string is read off the machine, not configured"
}

test_a_machine_mismatch_is_refused() {
  local tmp file
  tmp=$(dotfiles_test_tmproot dotfiles-settings)
  file="$tmp/flake.nix"

  # A configuration built for somebody else must never be built here: it would
  # manage a home directory that is not the user's.
  write_fixture "$file" definitely-not-this-user null
  ! flake_settings_check_machine "$file" 2>/dev/null \
    || fail "a configuration for another user was accepted"

  # The same for a home directory that is not this one, even when the username
  # matches - which is exactly the managed-Mac case.
  write_fixture "$file" "$(whoami)" '"/Volumes/accounts/somebody"'
  ! flake_settings_check_machine "$file" 2>/dev/null \
    || fail "a configuration for another home directory was accepted"

  # And the machine as it really is has to pass.
  write_fixture "$file" "$(whoami)" "\"$HOME\""
  flake_settings_check_machine "$file" \
    || fail "a configuration describing this machine was refused"

  pass "settings: a configuration built for another user or home is refused"
}

test_reads_the_repositorys_own_settings
test_null_home_directory_derives_from_the_user
test_explicit_home_directory_is_used_verbatim
test_writing_settings_round_trips
test_writing_preserves_the_rest_of_the_file
test_the_real_flake_takes_a_write
test_a_value_that_cannot_be_written_is_refused
test_a_missing_line_is_reported_not_guessed
test_the_architecture_is_read_off_the_machine
test_a_machine_mismatch_is_refused

test_summary
