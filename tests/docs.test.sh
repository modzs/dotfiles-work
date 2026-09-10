#!/usr/bin/env bash
# Tests for the two documentation claims that are load-bearing rather than
# decorative.
#
# The rest of this suite deliberately asserts against artifacts and not against
# prose, because prose is not what decides behaviour. These two are the
# exception, and both earned it:
#
# - README.md's summary of what gets written outside $HOME is the paragraph
#   somebody shows the people who administer their Mac. It used to say "It
#   writes inside your home directory. That is all it writes," which is true of
#   this configuration and not true of the Nix installer bootstrap.sh runs -
#   that one writes /etc/synthetic.conf, /etc/nix, LaunchDaemons, an APFS
#   volume and a block in /etc/zshrc. An inaccurate answer there is worse than
#   no answer.
# - HOW-TO.md is the document README.md sends people to in order to run this,
#   and it never said what gets installed or that Homebrew deliberately is not.
#   A user arriving from a personal dotfiles repo therefore had nothing to
#   correct the expectation that /Applications and `brew list` would fill up.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 2

test_readme_is_accurate_about_what_is_written_outside_home() {
  local readme

  readme=$(cat "$ROOT/README.md") || fail "could not read README.md"

  # The unqualified claim, which covered the installer as well as the
  # configuration and was wrong about the installer.
  assert_not_contains "$readme" "It writes inside your home directory. That is all it writes." \
    "README.md still makes the unqualified claim that nothing outside \$HOME is written"

  # What the installer really puts there. Each of these exists on a Mac that
  # has run bootstrap.sh, and each is something an IT department will ask about.
  for path in /etc/synthetic.conf /etc/nix/ /Library/LaunchDaemons /etc/zshrc "APFS"; do
    assert_contains "$readme" "$path" \
      "README.md does not mention $path, which the Nix installer writes"
  done

  # And the distinction the repo is careful about everywhere else has to
  # survive the correction: the configuration does not write these, the
  # third-party installer does.
  assert_contains "$readme" "This configuration writes inside your home directory" \
    "README.md should still say what the configuration itself writes"

  pass "docs: README.md is accurate about what the Nix installer writes outside \$HOME"
}

test_how_to_says_what_you_get_and_what_you_do_not() {
  local how_to homebrew_line clone_line

  how_to=$(cat "$ROOT/HOW-TO.md") || fail "could not read HOW-TO.md"

  assert_contains "$how_to" "You do not get Homebrew" \
    "HOW-TO.md should say Homebrew is deliberately absent"
  assert_contains "$how_to" "brew list" \
    "HOW-TO.md should say what an empty brew list means"
  assert_contains "$how_to" "Home Manager Apps" \
    "HOW-TO.md should say where the terminal apps go"
  assert_contains "$how_to" "Spotlight" \
    "HOW-TO.md should say Spotlight will not find them"

  # Before the clone command, not buried in troubleshooting at the bottom. The
  # expectation has to be corrected while the user is still reading, not after
  # they have concluded the run did nothing.
  homebrew_line=$(grep -n "You do not get Homebrew" "$ROOT/HOW-TO.md" | head -n1 | cut -d: -f1)
  clone_line=$(grep -n "git clone" "$ROOT/HOW-TO.md" | head -n1 | cut -d: -f1)
  [ -n "$homebrew_line" ] && [ -n "$clone_line" ] \
    || fail "could not locate the setup section in HOW-TO.md"
  [ "$homebrew_line" -lt "$clone_line" ] \
    || fail "HOW-TO.md explains what you get after the clone command, not before it"

  pass "docs: HOW-TO.md says what you get and what you do not, before the setup command"
}

test_readme_is_accurate_about_what_is_written_outside_home
test_how_to_says_what_you_get_and_what_you_do_not

test_summary
