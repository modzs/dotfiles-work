#!/usr/bin/env bash
# Behaviour tests for the Homebrew half of this configuration.
#
# This repository installs Homebrew and then drives it. Homebrew's source is a
# pinned flake input; home.nix patches the store copy and generates a `brew`
# around it; bootstrap.sh creates the standard prefix once, behind the single
# `sudo` in this repo; a Home Manager activation step links the two together on
# every switch; and a second step hands that Homebrew a generated Brewfile.
# That is where this configuration reaches outside the home directory, so what
# it does there is pinned here rather than described in prose - README.md and
# AGENTS.md say what the rules are; these checks are what holds the code to them.
#
# Seven properties, in order of how much damage getting them wrong would do:
#
# - a prefix holding a Homebrew this repo did not create is never converted,
#   migrated or deleted. It is reported and the run stops - at the preflight
#   before anything is installed, again as root immediately before writing, and
#   again in the activation step. On a work Mac, removing a package manager's
#   tree on the owner's behalf is the worst thing in this file;
# - the Brewfile step never removes anything, and cannot be talked into it.
#   Homebrew here is the user's general-purpose package manager, and the setup
#   this repo replaces drove it with `cleanup = "zap"`, which uninstalls
#   whatever the Brewfile does not list. Software installed by hand for
#   unrelated reasons - an employer's security agent included - must survive
#   every rebuild. That means passing no cleanup flag AND refusing the two
#   environment variables that turn a cleanup on without one;
# - the privileged step is idempotent and skips itself once the marker is
#   there, which is what makes root a once-per-machine cost rather than a
#   per-rebuild one;
# - the unprivileged step needs no root, and refuses with an explanation
#   pointing at bootstrap.sh rather than trying and failing on permissions;
# - the steps run in the right order: the prefix before the Brewfile, and both
#   after everything that writes the home directory;
# - nothing is installed by both Nix and Homebrew, because two copies on PATH
#   are decided by an ordering the user never chose;
# - the Brewfile lands inside the home directory, and lists what home.nix says.
#
# The steps are exercised by running them - the Brewfile step against a
# recording stand-in for `brew`, the prefix steps against a stand-in prefix in a
# temp directory. Asserting on source text would prove that the words are there;
# running it proves what it does with them. One check cannot work that way: the
# ordering, which is a property of the built activate script rather than of any
# step. It says so where it sits.
#
# Nothing here activates a configuration, nothing here runs `sudo`, and nothing
# here touches the real /opt/homebrew or /usr/local. See the standing rule in
# AGENTS.md, and the notes further down about the two outcomes this file
# deliberately leaves untested as a result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 28

SYSTEM=aarch64-darwin
case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-darwin ;;
esac

# What home.nix declares. Written out here rather than read back out of the
# configuration, so that this file is an independent statement of the expected
# contents and not a mirror that agrees with whatever home.nix happens to say.
EXPECTED_BREWFILE='brew "herdr"
brew "gh"
cask "wezterm"
cask "claude-code"
cask "ghostty"'

BREWFILE_TARGET=".config/dotfiles/Brewfile"

# --- the Brewfile is a managed file inside the home directory ------------------

test_brewfile_is_written_inside_the_home_directory() {
  local target global_paths
  if ! command -v nix >/dev/null 2>&1; then
    skip "Brewfile target check (nix not found)"
    return 0
  fi

  # Home Manager states file targets relative to the home directory, so the
  # question is whether this one is relative at all. tests/safety.test.sh makes
  # the same assertion over every managed file; this one names the Brewfile,
  # because the Brewfile is the file whose contents reach outside $HOME and it
  # is worth knowing that the file itself does not.
  target=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".config.home.file" \
    --apply "files:
      let matching = builtins.filter (f: f.target == \"$BREWFILE_TARGET\") (builtins.attrValues files);
      in builtins.concatStringsSep \" \" (map (f: f.target) matching)" \
    2>/dev/null) \
    || fail "could not evaluate the configuration's managed files"

  assert_eq "$target" "$BREWFILE_TARGET" \
    "the Brewfile is not a managed file at $BREWFILE_TARGET"

  # Not one of the paths `brew bundle --global` reads, so this generated list
  # is what Homebrew acts on when this step passes --file and at no other time.
  # A Brewfile sitting on that search path would also be picked up by a
  # `brew bundle` the user ran for an unrelated reason, a `cleanup` among them.
  #
  # This is not what keeps a cleanup from running - the environment variables
  # that turn one on are not gated on --global, and the step unsets them
  # itself. test_the_homebrew_step_neutralizes_the_cleanup_variables is the
  # check that covers that.
  global_paths=".config/homebrew/Brewfile .homebrew/Brewfile .Brewfile"
  for candidate in $global_paths; do
    [ "$BREWFILE_TARGET" != "$candidate" ] \
      || fail "the Brewfile is at $candidate, which \`brew bundle --global\` reads"
  done

  pass "homebrew: the Brewfile is a managed file inside \$HOME, off the --global search path"
}

# --- the Brewfile lists what home.nix declares, and nothing else --------------

test_brewfile_lists_exactly_the_declared_formulae_and_casks() {
  local generation brewfile directives
  if ! command -v nix >/dev/null 2>&1; then
    skip "Brewfile contents check (nix not found)"
    return 0
  fi

  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  brewfile="$generation/home-files/$BREWFILE_TARGET"
  [ -f "$brewfile" ] || fail "the generation writes no $BREWFILE_TARGET"

  # Comments and blank lines dropped, so this compares the directives Homebrew
  # will act on rather than the prose around them.
  directives=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$brewfile")

  assert_eq "$directives" "$EXPECTED_BREWFILE" \
    "the generated Brewfile is not the list home.nix declares"

  pass "homebrew: the generated Brewfile lists exactly the declared formulae and casks"
}

# --- the step installs, and can never remove ---------------------------------

# Run the Homebrew step against a stand-in `brew` that records its arguments and
# environment instead of doing anything. Prints the recording - a `home:` line
# naming the temp home it used, then whatever the stand-in was asked to do - and
# leaves the caller to decide what it means.
#
# The home directory is a temp root carrying a real copy of the generated
# Brewfile, because that is the state activation hands the step: `linkGeneration`
# has written it before this runs.
#
# Takes any number of NAME=VALUE pairs to export into the step's environment,
# and hands the step nothing else. What a caller passes decides what the
# recording can prove, and the two directions are not interchangeable: handing
# a variable in can only show whether the step cleared it, and leaving it out
# is the only way to see the step setting one of its own.
dotfiles_run_brew_step() {
  local root generation script status=0
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  root=$(dotfiles_test_tmproot dotfiles-brewstep)
  mkdir -p "$root/home/$(dirname "$BREWFILE_TARGET")" "$root/prefix/bin"
  cp "$generation/home-files/$BREWFILE_TARGET" "$root/home/$BREWFILE_TARGET"

  # The temp home is part of the recording: the caller has to know which
  # Brewfile path to expect in the arguments, and the path is only decided here.
  printf 'home: %s\n' "$root/home"

  cat >"$root/prefix/bin/brew" <<'STANDIN'
#!/bin/sh
# Records the call instead of making one. Nothing here installs, upgrades or
# removes anything: the point is to see what the step asks Homebrew to do.
printf 'argv: %s\n' "$*"
printf 'HOMEBREW_NO_AUTO_UPDATE: %s\n' "${HOMEBREW_NO_AUTO_UPDATE-<unset>}"
printf 'HOMEBREW_BUNDLE_INSTALL_CLEANUP: %s\n' "${HOMEBREW_BUNDLE_INSTALL_CLEANUP-<unset>}"
printf 'HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP: %s\n' "${HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP-<unset>}"
STANDIN
  chmod +x "$root/prefix/bin/brew"

  # env -i, so the recording reflects what the step sets rather than what the
  # shell running the suite happened to export. PATH is deliberately useless:
  # Home Manager's activation replaces PATH before running this, and the step
  # has to find Homebrew without it. The caller's pairs go last, so a test can
  # hand the step whatever environment it needs to be tested against.
  env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$root/prefix" \
    "$@" \
    "$script" "$root/prefix" 2>&1 || status=$?

  [ "$status" = 0 ] || fail "the Homebrew step failed against a stand-in brew (exit $status)"
}

test_the_homebrew_step_installs_and_cannot_remove() {
  local recording home argv word
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew step invocation check (nix not found)"
    return 0
  fi

  recording=$(dotfiles_run_brew_step) \
    || fail "could not run the Homebrew step against a stand-in brew"
  home=$(printf '%s\n' "$recording" | sed -n 's/^home: //p')
  argv=$(printf '%s\n' "$recording" | sed -n 's/^argv: //p')

  assert_eq "$argv" "bundle install --file $home/$BREWFILE_TARGET --no-upgrade --force" \
    "the Homebrew step does not run \`brew bundle install --file <Brewfile> --no-upgrade --force\`"

  # Every way `brew bundle` can be made to uninstall something. The subcommand
  # is `install`, asserted above; these are the flags that would turn even that
  # into a removal, plus `--global`, which is banned for a different reason: it
  # would have Homebrew read a Brewfile off its own search path instead of the
  # generated one this step passes with --file, so the list being applied would
  # no longer be the list home.nix declares.
  #
  # `--global` is NOT what gates the two cleanup environment variables, whatever
  # Homebrew's help text implies. See
  # test_the_homebrew_step_neutralizes_the_cleanup_variables below, which is
  # where that mechanism is described and checked.
  for word in cleanup --cleanup --force-cleanup --zap -g --global uninstall remove; do
    case " $argv " in
      *" $word "*) fail "the Homebrew step passes $word, which can uninstall software the user installed by hand" ;;
    esac
  done

  # Separate, because it is a different defect with a different diagnosis.
  # `--upgrade` removes nothing; it would make a rebuild replace the versions
  # of already-installed formulae and casks, which the reference configuration
  # does not do - nix-darwin's `onActivation.upgrade` defaults to false. The
  # `--no-upgrade` the step really passes does not trip this: the guard
  # compares whole space-delimited words.
  case " $argv " in
    *" --upgrade "*) fail "the Homebrew step passes --upgrade, so a rebuild replaces versions of already-installed packages the user never asked it to touch" ;;
  esac

  pass "homebrew: the step runs \`brew bundle install\` and passes nothing that can uninstall or upgrade"
}

test_the_homebrew_step_does_not_touch_auto_update() {
  local recording
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew auto-update check (nix not found)"
    return 0
  fi

  # HOMEBREW_NO_AUTO_UPDATE is the user's to decide, and the step must leave it
  # exactly as it found it. That is what nix-darwin's `onActivation.autoUpdate
  # = true` amounts to: it declines to *set* the variable, and it never clears
  # one the user exported - which someone on a slow or proxied network has
  # every reason to have done.
  #
  # Two runs, because one cannot see both failures. Starting from an
  # environment where the variable is absent is the only way to catch the step
  # setting one of its own - `export HOMEBREW_NO_AUTO_UPDATE=1`, which is
  # nix-darwin's spelling of `autoUpdate = false` and so the likeliest
  # regression here. A run that is handed a value cannot: the value would come
  # back either way.
  recording=$(dotfiles_run_brew_step) \
    || fail "could not run the Homebrew step against a stand-in brew"

  assert_contains "$recording" "HOMEBREW_NO_AUTO_UPDATE: <unset>" \
    "the Homebrew step sets HOMEBREW_NO_AUTO_UPDATE itself, which turns auto-update off"

  # And starting from a value the caller exported is the only way to catch the
  # step clearing it, which is what this configuration used to do.
  recording=$(dotfiles_run_brew_step HOMEBREW_NO_AUTO_UPDATE=1) \
    || fail "could not run the Homebrew step against a stand-in brew"

  assert_contains "$recording" "HOMEBREW_NO_AUTO_UPDATE: 1" \
    "the Homebrew step cleared HOMEBREW_NO_AUTO_UPDATE instead of leaving the user's value alone"

  pass "homebrew: the step neither sets nor clears HOMEBREW_NO_AUTO_UPDATE"
}

test_the_homebrew_step_neutralizes_the_cleanup_variables() {
  local recording
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew cleanup variable check (nix not found)"
    return 0
  fi

  # The one check standing between this repository and the disaster it exists
  # to prevent. `brew bundle install` takes its `--cleanup` and
  # `--force-cleanup` switches from the environment as well as from argv, and
  # with either set it uninstalls every formula and cask not in the Brewfile -
  # an employer's security agent among them. Both variables are plausible on a
  # real machine: a shell profile, ~/.zshrc.local, or a managed configuration
  # profile can export them without the user thinking about this repo at all.
  #
  # Two things make this worth a check of its own rather than a line in the
  # banned-word loop above. The loop reads argv, and argv is exactly where this
  # does not appear - which is why it passed while the behaviour was reachable.
  # And Homebrew's help text says these are enabled "if $VAR is set and
  # --global is passed", which is not what its parser does: the --global half
  # is documentation, and the variable is honoured on its own.
  #
  # So the step is handed both, set to the value that turns them on, and the
  # stand-in has to report both absent.
  recording=$(dotfiles_run_brew_step \
    HOMEBREW_BUNDLE_INSTALL_CLEANUP=1 \
    HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP=1) \
    || fail "could not run the Homebrew step against a stand-in brew"

  assert_contains "$recording" "HOMEBREW_BUNDLE_INSTALL_CLEANUP: <unset>" \
    "HOMEBREW_BUNDLE_INSTALL_CLEANUP reached Homebrew, so a rebuild would uninstall everything not in the Brewfile"
  assert_contains "$recording" "HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP: <unset>" \
    "HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP reached Homebrew, so a rebuild would uninstall everything not in the Brewfile"

  # Setting them to "0" must not be mistaken for a fix if anyone ever tries it:
  # Homebrew asks whether the value is present, not whether it is true.
  recording=$(dotfiles_run_brew_step \
    HOMEBREW_BUNDLE_INSTALL_CLEANUP=0 \
    HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP=0) \
    || fail "could not run the Homebrew step against a stand-in brew"

  assert_contains "$recording" "HOMEBREW_BUNDLE_INSTALL_CLEANUP: <unset>" \
    "HOMEBREW_BUNDLE_INSTALL_CLEANUP reached Homebrew as \"0\", which Homebrew reads as set"
  assert_contains "$recording" "HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP: <unset>" \
    "HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP reached Homebrew as \"0\", which Homebrew reads as set"

  pass "homebrew: the step unsets both Homebrew cleanup variables, whatever the environment exports"
}

# --- the step runs after the Brewfile has been written -------------------------

# The line number at which the built activate script announces a named
# activation step, or empty if it never does.
dotfiles_activation_line() {
  local generation=$1 name=$2
  grep -n "\"$name\"\$" "$generation/activate" \
    | grep 'Activating' \
    | sed -n 's/^\([0-9][0-9]*\):.*/\1/p' \
    | head -n1
}

test_the_homebrew_step_runs_after_the_brewfile_is_written() {
  local generation bundle link install onchange
  if ! command -v nix >/dev/null 2>&1; then
    skip "activation ordering check (nix not found)"
    return 0
  fi

  # Read out of the BUILT activate script, which is generated public output -
  # the activation contract Home Manager executes, in the order it executes it
  # - and not implementation source. The order is not visible in home.nix at
  # all: `writeBoundary` is a barrier that writes nothing, so an entry naming
  # only it is ordered against its siblings by attribute name, and
  # `homebrewBundle` sorts ahead of all three steps below. Nothing else in this
  # suite can see it, because the other checks run the step directly against a
  # Brewfile they placed themselves.
  #
  # Each edge is asserted separately, because each one fails differently and
  # the failure messages are the only place that difference is written down.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"

  bundle=$(dotfiles_activation_line "$generation" homebrewBundle)
  link=$(dotfiles_activation_line "$generation" linkGeneration)
  install=$(dotfiles_activation_line "$generation" installPackages)
  onchange=$(dotfiles_activation_line "$generation" onFilesChange)

  [ -n "$bundle" ] || fail "the activation script never activates homebrewBundle"
  [ -n "$link" ] || fail "the activation script never activates linkGeneration"
  [ -n "$install" ] || fail "the activation script never activates installPackages"
  [ -n "$onchange" ] || fail "the activation script never activates onFilesChange"

  # linkGeneration writes ~/.config/dotfiles/Brewfile. Reading it before then
  # is the difference between applying the list in home.nix and applying the
  # one from the last rebuild.
  [ "$bundle" -gt "$link" ] \
    || fail "the Homebrew step runs before linkGeneration, so it reads a Brewfile that has not been written yet"

  # Not correctness, but a documented promise: README.md, HOW-TO.md and
  # bootstrap.sh all tell the user that when Homebrew is missing, everything
  # Nix installs is already in place. Activation runs under `set -eu`, so that
  # is only true if the Nix half has finished first.
  [ "$bundle" -gt "$install" ] \
    || fail "the Homebrew step runs before installPackages, so its failure would leave the Nix half unapplied"

  # This is the edge whose absence does permanent damage, and the reason is not
  # visible from the edge itself. onFilesChange holds the rsync that installs
  # the font into ~/Library/Fonts, and it is guarded by a marker file that
  # linkGeneration has already placed in $HOME by the time the Homebrew step
  # runs. A Mac with no Homebrew therefore aborts activation in between: the
  # marker is in place, the font was never copied, and the next rebuild
  # compares the marker against the store, sees no change, and skips the rsync
  # again. The font never installs and never self-heals, so the prompt renders
  # tofu until the font derivation itself changes.
  [ "$bundle" -gt "$onchange" ] \
    || fail "the Homebrew step runs before onFilesChange, so a failure strands the font rsync behind a marker that is already in place"

  pass "homebrew: the step activates after the Brewfile, the Nix packages and the on-change hooks"
}

# --- what is deliberately NOT tested here --------------------------------------
#
# There is no test that a failed Homebrew step still leaves the font installed.
# The check above pins the ORDER that protects that outcome; it does not pin the
# outcome. That gap is deliberate and it should stay visible rather than be
# papered over.
#
# A test for the outcome would have to run a real activation, and one was
# written and then removed. The reasons it cannot come back:
#
# - a test that really activates is the one artifact in this tree capable of
#   breaking the repository's central claim, and its safety would rest on a list
#   of machine-global paths being complete AND STAYING complete;
# - today's list is correct; tomorrow's is a different list. The `/bin/launchctl`
#   path is inert only because no launchd agent is declared, and it re-arms
#   silently the day someone adds one, with nothing failing loudly at that
#   moment. A guard that depends on a future contributor not adding a feature is
#   not a guard;
# - `./tests/run.sh` is listed in HOW-TO.md under "See what would happen, without
#   changing anything". On a Mac carrying the pre-Nix-2.14 layout, that test
#   would have destroyed the user's Home Manager profile and every generation
#   before any sanity check could abort - `migrateProfile` runs its `rm` against
#   the real per-user Nix state well before the USER and HOME checks.
#
# AGENTS.md carries the standing rule and the full list of paths a redirected
# homeDirectory does not redirect.

# --- the prefix: created once, never converted, never needing root ------------
#
# This is the half of the Homebrew story that is new, and the half that can do
# real damage. Everything below runs against a stand-in prefix in a temp
# directory: a real one is /opt/homebrew or /usr/local, both absolute and
# unredirectable, and a test that wrote to either would be reconfiguring the
# machine running the suite.
#
# That stand-in is possible because the library takes the prefix as an argument
# rather than reading it from the environment. The prefix a real run uses is
# decided by the architecture and by nothing else - see
# test_the_prefix_the_setup_step_manages_is_this_architectures - so there is no
# variable a test could point somewhere safe even if one were wanted.

# Ask lib/homebrew-present.sh a question in a clean bash, the way AGENTS.md
# requires: sourcing repo libraries into the suite's own shell is how a function
# comes to be tested against a definition that is not the one production uses.
dotfiles_homebrew_lib() {
  /bin/bash -c '. "$1/lib/homebrew-present.sh"; shift; "$@"' _ "$ROOT" "$@"
}

# A prefix directory that exists and has no Homebrew in it - the state of
# /usr/local on every Intel Mac, and of /opt/homebrew on a Mac that has never
# had Homebrew.
dotfiles_fresh_prefix() {
  local root
  root=$(dotfiles_test_tmproot dotfiles-prefix)
  mkdir -p "$root/prefix"
  printf '%s\n' "$root/prefix"
}

# Run the privileged initializer against a stand-in prefix, as the current user
# rather than as root.
#
# Unprivileged is not a compromise here, it is most of the point: everything the
# script does after the prefix directory exists is a mkdir, a chmod, or a chown
# and chgrp to the caller's own account, and macOS permits all of those to the
# owner. The one branch that genuinely needs root is
# `/usr/bin/install -d -o root -g wheel`, which only runs when the prefix
# directory does not exist at all, and every fixture below creates it first.
# What that leaves untested is named in the note at the end of this section.
dotfiles_run_initializer() {
  local prefix=$1
  /bin/bash "$ROOT/lib/homebrew-initialize-prefix.sh" \
    "$prefix" "$prefix/Library" "$(whoami)" "$(id -gn)" 2>&1
}

# Run bootstrap.sh's preflight against a stand-in prefix, with HOMEBREW_PREFIX
# set to $1 and the prefix to judge in $2.
#
# The environment is set explicitly rather than inherited, and that is not
# tidiness. The preflight now asks dotfiles_homebrew_find whether this machine
# already has a Homebrew somewhere other than the prefix it is about to set up,
# and with HOMEBREW_PREFIX unset that search probes the real /opt/homebrew and
# /usr/local. Inheriting it would make every check below answer differently on a
# machine that happens to have Homebrew installed - which is every developer
# machine and every CI runner. Pointing it at the stand-in is what keeps these
# checks about their own fixture; the new check points it somewhere else on
# purpose, which is the case it exists for.
dotfiles_run_preflight() {
  local env_prefix=$1 prefix=$2
  # shellcheck disable=SC2016  # $1 and $2 are the inner shell's arguments
  env HOMEBREW_PREFIX="$env_prefix" /bin/bash -c \
    '. "$1/lib/homebrew-present.sh"; dotfiles_homebrew_preflight "$2" "$2/Library"' \
    _ "$ROOT" "$prefix" 2>&1
}

test_the_privileged_step_creates_the_prefix_and_marks_it() {
  local prefix output status=0

  prefix=$(dotfiles_fresh_prefix)

  output=$(dotfiles_run_initializer "$prefix") || status=$?
  [ "$status" = 0 ] || fail "the initializer failed against a stand-in prefix (exit $status): $output"

  # Homebrew's own layout. Not every directory it creates - that list is
  # upstream's and it moves - but the ones whose absence would break a `brew
  # install` on the first run.
  for dir in bin etc lib share var opt Cellar Caskroom Frameworks var/homebrew; do
    [ -d "$prefix/$dir" ] \
      || fail "the initializer did not create $dir in the prefix"
  done
  [ -d "$prefix/Library" ] \
    || fail "the initializer did not create the Homebrew library directory"

  # The marker, which is the whole hinge: it is what every later run reads to
  # decide that root is not needed again.
  [ -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the initializer did not leave the marker, so every rebuild would ask for a password"

  # And the property that makes the rest of this configuration unprivileged: the
  # two directories activation writes into belong to this account now.
  [ -w "$prefix/Library" ] \
    || fail "the initializer left the library unwritable by its owner"
  [ -w "$prefix/bin" ] \
    || fail "the initializer left bin unwritable by its owner"

  pass "prefix: the privileged step creates Homebrew's layout, marks it, and hands it over"
}

test_the_privileged_step_does_nothing_the_second_time() {
  local prefix output status=0 before after

  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed on its first run"

  # A marker whose timestamp can be compared. The question this answers is not
  # "did it print something reassuring" but "did it write again at all" - a
  # second run that redid the chowns would be asking for a password on every
  # bootstrap, which is the cost this design exists to pay only once.
  before=$(ls -lT "$prefix/.managed_by_nix_darwin")
  output=$(dotfiles_run_initializer "$prefix") || status=$?
  after=$(ls -lT "$prefix/.managed_by_nix_darwin")

  [ "$status" = 0 ] || fail "the initializer failed on an already-managed prefix (exit $status): $output"
  assert_contains "$output" "already set up" \
    "the initializer did not say it had nothing to do"
  assert_eq "$after" "$before" \
    "the initializer rewrote the marker on a prefix that was already managed"

  pass "prefix: the privileged step recognises its own marker and does nothing twice"
}

test_the_privileged_step_refuses_a_homebrew_it_did_not_install() {
  local prefix output status=0

  # What an existing Homebrew looks like from outside: a real directory at
  # $HOMEBREW_LIBRARY/Homebrew. That is the shape on both architectures, which
  # is why nix-homebrew tests that path and why this does.
  prefix=$(dotfiles_fresh_prefix)
  mkdir -p "$prefix/Library/Homebrew"
  printf 'pretend this is Homebrew\n' >"$prefix/Library/Homebrew/brew.sh"

  output=$(dotfiles_run_initializer "$prefix") || status=$?

  [ "$status" != 0 ] \
    || fail "the initializer accepted a prefix that already contains a Homebrew"

  # It must still be there, untouched. This is the assertion the whole design
  # turns on: the owner's instruction was that an existing Homebrew is never
  # converted and never removed, and a message saying so would be worthless if
  # the tree were gone.
  [ -f "$prefix/Library/Homebrew/brew.sh" ] \
    || fail "the initializer removed part of an existing Homebrew, which it must never do"
  [ ! -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the initializer marked a prefix it refused, so a later run would treat it as managed"

  assert_contains "$output" "$prefix/Library/Homebrew" \
    "the refusal does not name what it found in the way"
  assert_contains "$output" "Nothing has been changed" \
    "the refusal does not say that nothing was changed"
  assert_contains "$output" "uninstall the existing one yourself" \
    "the refusal does not say what the user can do about it"

  pass "prefix: the privileged step refuses an existing Homebrew and leaves it exactly as it is"
}

# A directory inside the prefix that the run cannot hand to the account.
#
# The real shape of this is an Intel Mac whose /usr/local/bin already exists
# root:wheel, because something else installed there first - and that cannot be
# built in a test, because creating a root-owned directory needs root and no
# test here may have it. A directory whose mode denies its own owner write is
# the same condition reached unprivileged: the run cannot write it, and taking
# it over is the thing this repository refuses to do.
#
# Both are decided by the same code and the same question - ownership and mode,
# read with stat rather than with `[ -w ]` - which is what makes one stand in
# for the other. `[ -w ]` is exactly what does not work: the privileged step
# runs as root, for whom it is true of every path on the machine, which is how
# this shipped broken in the first place.
dotfiles_unhandable_dir() {
  mkdir -p "$1" || fail "could not create the fixture directory $1"
  chmod 0500 "$1" || fail "could not take write permission off $1"
}

test_the_privileged_step_refuses_a_prefix_it_cannot_hand_over() {
  local prefix output status=0

  prefix=$(dotfiles_fresh_prefix)
  dotfiles_unhandable_dir "$prefix/bin"

  output=$(dotfiles_run_initializer "$prefix") || status=$?

  [ "$status" != 0 ] \
    || fail "the initializer accepted a prefix holding a directory it cannot hand over"

  # The clause that closes the loop, and the reason this is a regression rather
  # than a nicety. The marker means "set up, no password needed ever again", so
  # leaving one on a prefix that was never handed over made bootstrap.sh report
  # success and every switch afterwards fail, with no way out of either.
  [ ! -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the initializer marked a prefix it could not hand over"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    unusable "a prefix the initializer refused is still reported as something a rebuild could use"

  # And it refused before writing, not after.
  [ ! -d "$prefix/Cellar" ] \
    || fail "the initializer built out a prefix it then refused"

  assert_contains "$output" "$prefix/bin" \
    "the refusal does not name the directory that is in the way"
  assert_contains "$output" "Nothing has been changed" \
    "the refusal does not say that nothing was changed"
  assert_contains "$output" "./bootstrap.sh" \
    "the refusal does not say what the user can do about it"

  chmod 0755 "$prefix/bin"

  pass "prefix: the privileged step refuses a prefix it cannot hand over, and leaves it unmarked"
}

test_a_marked_prefix_this_account_cannot_use_is_not_managed() {
  local prefix output status=0

  # A prefix that really was set up - by this repository, with the marker to
  # prove it - and has since stopped being usable by this account. The shape
  # that matters in the field is a prefix marked for a different user.
  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    managed "the fixture prefix was not managed to begin with, so this proves nothing"

  chmod 0500 "$prefix/bin" || fail "could not take write permission off the fixture bin"

  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    unusable "a marked prefix this account cannot write is still reported as managed"

  # Which is what stops the loop: the preflight is the branch that used to print
  # "already set up; no password needed" and move on, leaving the switch to fail
  # and send the user back to bootstrap.sh for ever.
  output=$(dotfiles_run_preflight "$prefix" "$prefix") || status=$?
  [ "$status" != 0 ] \
    || fail "the preflight accepted a marked prefix this account cannot use"
  assert_not_contains "$output" "already set up" \
    "the preflight reported a prefix this account cannot use as finished"
  assert_contains "$output" "$prefix/bin" \
    "the preflight does not name the directory that is in the way"

  chmod 0755 "$prefix/bin"

  pass "prefix: a marked prefix this account cannot use is refused rather than called managed"
}

test_a_marked_prefix_that_lost_its_directories_is_refused_before_ln() {
  local prefix output status=0

  # The reproduction, in the order a real user reaches it. Bootstrap succeeds;
  # later the user follows Homebrew's own uninstall instructions - HOW-TO.md
  # points at them - which takes the prefix's directories away and leaves this
  # repository's marker behind.
  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  rm -rf "${prefix:?}/bin" "${prefix:?}/Library"
  [ -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the fixture lost the marker, so this proves nothing"

  # The marker promised these paths. Reporting the prefix as managed is what
  # sent bootstrap.sh past the only step that could rebuild them.
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    unusable "a marked prefix that no longer holds what the marker promises is still reported as managed"

  output=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_link \
    "$prefix" "$prefix/Library" /nix/store/unused-code /nix/store/unused-brew 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the setup step accepted a prefix that no longer holds what the marker promises"

  # It has to refuse rather than reach `ln` and die on a raw errno message. That
  # death under `set -eu` was the whole failure: no explanation, no troubleshooting
  # entry, and no way out but deleting the marker by hand.
  assert_not_contains "$output" "ln:" \
    "the setup step reached ln instead of refusing, so the failure is a raw errno again"
  assert_contains "$output" "$prefix/bin" \
    "the refusal does not name the path that went missing"
  assert_contains "$output" "(missing)" \
    "the refusal does not distinguish a missing path from one that is somebody else's"
  assert_contains "$output" ".managed_by_nix_darwin" \
    "the refusal does not say that removing the marker redoes the setup"

  # And the way out actually works: without the marker nothing is promised, so
  # the prefix is fresh again and the privileged step will rebuild it.
  rm -f "$prefix/.managed_by_nix_darwin"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    fresh "removing the marker does not return the prefix to a state bootstrap.sh would set up"

  pass "prefix: a marked prefix that lost its directories is refused with an explanation, never inside ln"
}

test_homebrews_own_pruning_does_not_lock_the_prefix() {
  local prefix output status=0

  # The other half of the rule above, and the case a future widening breaks
  # first. HOMEBREW DELETES MOST OF THE PREFIX'S DIRECTORIES ITSELF. Its
  # `Keg.must_exist_subdirectories` is `bin etc include lib sbin share opt
  # var/homebrew/linked`; everything else it linked into is rmdir'd once empty
  # by `Keg#unlink`, and `Cleanup#prune_prefix_symlinks_and_directories` removes
  # them on a schedule with no user action at all. `share/zsh/site-functions` is
  # the one every user meets: install `gh`, uninstall it, and both zsh
  # directories are gone.
  #
  # So a prefix has to survive that. Requiring them made `brew uninstall gh`
  # lock the prefix permanently, with no way back but deleting the marker and
  # spending the one password this repository promises a rebuild never needs.
  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  [ -d "$prefix/share/zsh/site-functions" ] \
    || fail "the initializer did not create the directories this check is about"

  rmdir "$prefix/share/zsh/site-functions" "$prefix/share/zsh" \
    || fail "could not prune the zsh directories the way Homebrew does"

  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    managed "a prefix Homebrew pruned its own directories out of is no longer reported as managed"

  output=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_link \
    "$prefix" "$prefix/Library" /nix/store/unused-code /nix/store/unused-brew 2>&1) || status=$?
  [ "$status" = 0 ] \
    || fail "the setup step refused a prefix Homebrew had pruned (exit $status): $output"
  assert_eq "$(readlink "$prefix/bin/brew")" /nix/store/unused-brew \
    "the setup step did not link the launcher into a pruned prefix"
  assert_eq "$(readlink "$prefix/Library/Homebrew")" /nix/store/unused-code \
    "the setup step did not link the Homebrew code into a pruned prefix"

  # And no password is implied: the marker is still there, so bootstrap.sh's
  # privileged step stays skipped.
  [ -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the marker was removed, so the next bootstrap would ask for a password again"

  pass "prefix: a prefix Homebrew pruned its own directories out of still works, with no password"
}

test_the_prefix_setup_step_links_homebrew_without_root() {
  local prefix output status=0 target
  if ! command -v nix >/dev/null 2>&1; then
    skip "prefix setup check (nix not found)"
    return 0
  fi

  # The real store paths, out of the built artifact, so this exercises the code
  # activation runs against the files activation links.
  #
  # The patched Homebrew tree is read out of the script here rather than through
  # a shared helper, because the only other caller - the artifact path scan in
  # tests/safety.test.sh - must NOT have it: that scan walks every file it is
  # given, and this one is a directory holding all of upstream Homebrew.
  local generation setup extra library binary code
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  setup=$(dotfiles_homebrew_prefix_script "$generation") \
    || fail "the activation script does not run a Homebrew prefix-setup step at all"
  extra=$(dotfiles_homebrew_prefix_script_files "$setup") \
    || fail "the prefix-setup step names neither a library to source nor a brew to link"
  library=$(printf '%s\n' "$extra" | sed -n 1p)
  binary=$(printf '%s\n' "$extra" | sed -n 2p)
  code=$(sed -n 's|^brew_code="\(.*\)"$|\1|p' "$setup" | head -n1)
  [ -n "$code" ] || fail "the prefix-setup step names no Homebrew code to link"
  [ -d "$code" ] || fail "the Homebrew code the prefix-setup step names is not there"

  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"

  # The library out of the STORE, not out of the working tree: that is the copy
  # the activation step sources, and a test reading the other one would pass
  # while the built artifact was broken.
  output=$(/bin/bash -c \
    '. "$1"; dotfiles_homebrew_prefix_link "$2" "$2/Library" "$3" "$4"' \
    _ "$library" "$prefix" "$code" "$binary" 2>&1) || status=$?
  [ "$status" = 0 ] || fail "the prefix-setup step failed against a prepared prefix (exit $status): $output"

  # Code from the store, state in the prefix. A symlink and not a copy is the
  # property that makes a pinned Homebrew pinned: there is no checkout here for
  # `brew update` to fast-forward.
  [ -L "$prefix/Library/Homebrew" ] \
    || fail "the setup step did not symlink the Homebrew code into the prefix"
  target=$(readlink "$prefix/Library/Homebrew")
  assert_eq "$target" "$code" \
    "the setup step linked the Homebrew code somewhere other than where it was told"

  [ -L "$prefix/bin/brew" ] \
    || fail "the setup step did not link a brew into the prefix"
  target=$(readlink "$prefix/bin/brew")
  assert_eq "$target" "$binary" \
    "the setup step linked a brew other than the generated one"

  # The fake repository Homebrew insists on finding. It is not a git repository
  # and is not meant to be one; what matters is that it exists and that .git/HEAD
  # is there for Homebrew's version probe to read.
  [ -f "$prefix/Library/.homebrew-is-managed-by-nix/.git/HEAD" ] \
    || fail "the setup step did not build the repository directory Homebrew expects"

  # Idempotent, because it runs on every switch. A second call must reach the
  # same state rather than tripping over its own symlinks.
  output=$(/bin/bash -c \
    '. "$1"; dotfiles_homebrew_prefix_link "$2" "$2/Library" "$3" "$4"' \
    _ "$library" "$prefix" "$code" "$binary" 2>&1) || status=$?
  [ "$status" = 0 ] || fail "the prefix-setup step failed on a second run (exit $status): $output"
  assert_eq "$(readlink "$prefix/Library/Homebrew")" "$code" \
    "a second run of the setup step did not leave the code link where the first did"

  pass "prefix: the setup step links the store Homebrew into a prepared prefix, twice over"
}

test_the_prefix_setup_step_refuses_a_prefix_bootstrap_has_not_prepared() {
  local prefix output status=0

  # A prefix with nothing in it: the state before bootstrap.sh's step 5. The
  # setup step must not try to create it - that needs root, and root belongs to
  # bootstrap.sh - so it has to stop and say where the fix is.
  prefix=$(dotfiles_fresh_prefix)

  output=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_link \
    "$prefix" "$prefix/Library" /nix/store/unused-code /nix/store/unused-brew 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the setup step accepted a prefix that has never been initialized"
  [ ! -e "$prefix/bin" ] \
    || fail "the setup step wrote into a prefix it had not been given"

  assert_contains "$output" "./bootstrap.sh" \
    "the failure does not point at the script that creates the prefix"
  assert_not_contains "$output" "Permission denied" \
    "the setup step tried and failed on permissions instead of checking first"

  pass "prefix: the setup step refuses an unprepared prefix and points at bootstrap.sh"
}

test_the_prefix_setup_step_refuses_a_homebrew_it_did_not_install() {
  local prefix output status=0

  # The same refusal as the privileged step's, from the other end of the run. A
  # machine can acquire a Homebrew between bootstrap and a later rebuild, and
  # the switch must not quietly link over it.
  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  rm -rf "$prefix/Library/Homebrew"
  mkdir -p "$prefix/Library/Homebrew"
  printf 'pretend this is Homebrew\n' >"$prefix/Library/Homebrew/brew.sh"

  output=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_link \
    "$prefix" "$prefix/Library" /nix/store/unused-code /nix/store/unused-brew 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the setup step linked over a Homebrew this repository did not install"
  [ -f "$prefix/Library/Homebrew/brew.sh" ] \
    || fail "the setup step removed part of an existing Homebrew, which it must never do"
  assert_contains "$output" "refusing to touch $prefix" \
    "the refusal does not name the prefix it refused"

  pass "prefix: the setup step refuses an existing Homebrew even on a marked prefix"
}

test_the_prefix_state_tells_the_three_cases_apart() {
  local prefix

  # The one function all three refusals above are built on, asked directly.
  # Each of the checks that use it passes by the state coming out right, which
  # is also what a function stuck on one answer would look like.
  prefix=$(dotfiles_fresh_prefix)
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    fresh "an empty prefix directory is not reported as fresh"

  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    managed "an initialized prefix is not reported as managed"

  # A symlink into the store is ours; anything else is not. Both directions
  # matter: reporting our own links as occupied would make every second switch
  # fail, and reporting a real directory as ours is the failure that deletes
  # somebody's Homebrew.
  mkdir -p "$prefix/bin"
  ln -shf /nix/store/whatever-brew "$prefix/bin/brew"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    managed "a brew symlinked into the Nix store is not recognised as this repository's own"

  rm -f "$prefix/bin/brew"
  printf '#!/bin/sh\n' >"$prefix/bin/brew"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    occupied "a real brew file in the prefix is not reported as occupied"

  # A symlink pointing somewhere that is not the store is not ours either - a
  # Homebrew someone relocated, say. Fail closed.
  rm -f "$prefix/bin/brew"
  ln -shf /usr/bin/true "$prefix/bin/brew"
  assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_prefix_state "$prefix" "$prefix/Library")" \
    occupied "a brew symlinked outside the Nix store is not reported as occupied"

  pass "prefix: the state check tells fresh, managed and occupied apart, and fails closed"
}

# --- the preflight says what will happen, before anything is installed --------
#
# The activation step's message arrives at the end of a switch. On a first
# bootstrap that is too late to be useful: Nix has been installed, a password
# has been asked for, and the home directory has been written. So bootstrap.sh
# asks the same questions up front, through lib/homebrew-present.sh, and these
# checks run that library directly rather than running bootstrap.sh - which
# would install Nix.
#
# What the preflight refuses has inverted, and that is the point of these two.
# It used to refuse a Mac with no Homebrew, because this repo could not install
# one. It now refuses a Mac whose prefix already HAS one, because it will not
# convert what it did not create - and an absent Homebrew is the ordinary state
# of the machine this is designed for.

test_the_preflight_refuses_a_prefix_that_already_has_a_homebrew() {
  local prefix output status=0

  prefix=$(dotfiles_fresh_prefix)
  mkdir -p "$prefix/Library/Homebrew"

  output=$(dotfiles_run_preflight "$prefix" "$prefix") || status=$?

  [ "$status" != 0 ] \
    || fail "the preflight accepted a prefix holding a Homebrew this repo did not install"

  assert_contains "$output" "$prefix/Library/Homebrew" \
    "the preflight does not name what it found in the way"
  assert_contains "$output" "Nothing has been installed yet" \
    "the preflight does not say that stopping here costs nothing"
  assert_not_contains "$output" "command not found" \
    "the preflight let the shell report a missing command instead of explaining"

  pass "preflight: a Mac with its own Homebrew is refused before anything is installed"
}

test_the_preflight_accepts_a_mac_with_no_homebrew_and_says_what_it_will_do() {
  local prefix output status=0

  # The case that used to be a refusal. A fresh work Mac has no Homebrew, this
  # configuration installs one, and the user is told that a password is coming
  # rather than being turned away.
  prefix=$(dotfiles_fresh_prefix)

  output=$(dotfiles_run_preflight "$prefix" "$prefix") || status=$?

  [ "$status" = 0 ] \
    || fail "the preflight refused a Mac with no Homebrew, which is the machine this is for (exit $status)"
  assert_contains "$output" "$prefix" \
    "the preflight does not say which prefix it is talking about"
  assert_contains "$output" "password" \
    "the preflight does not warn that creating the prefix needs a password"

  # And the already-done case, which is what a re-run of bootstrap.sh sees.
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  output=$(dotfiles_run_preflight "$prefix" "$prefix") || status=$?
  [ "$status" = 0 ] \
    || fail "the preflight refused a prefix it had already set up (exit $status)"
  assert_contains "$output" "already set up" \
    "the preflight does not say the prefix is already done"
  assert_not_contains "$output" "password" \
    "the preflight still warns about a password on a prefix that needs none"

  pass "preflight: a Mac with no Homebrew is accepted, and told which step will ask for a password"
}

test_the_preflight_refuses_a_homebrew_outside_the_managed_prefix() {
  local prefix foreign output status=0

  # The Mac this repository is actually for, in the shape that used to slip
  # through: an Apple silicon machine carrying an Intel Homebrew at /usr/local,
  # with Homebrew's own `eval "$(/usr/local/bin/brew shellenv)"` line in its
  # profile - which exports HOMEBREW_PREFIX. The prefix this configuration
  # manages is decided by the architecture, so it is empty and looks fresh,
  # while the Homebrew the shell actually reaches is somewhere else entirely.
  #
  # What used to happen: the preflight announced "no Homebrew in it", the run
  # spent the one password creating a prefix, and the Brewfile step then
  # followed HOMEBREW_PREFIX and installed every formula and cask into the OTHER
  # Homebrew. No error anywhere, and the prefix the password paid for unused.
  prefix=$(dotfiles_fresh_prefix)
  foreign=$(dotfiles_fresh_prefix)
  mkdir -p "$foreign/bin"
  printf '#!/bin/sh\nexit 0\n' >"$foreign/bin/brew"
  chmod +x "$foreign/bin/brew"

  output=$(dotfiles_run_preflight "$foreign" "$prefix") || status=$?

  [ "$status" != 0 ] \
    || fail "the preflight accepted a Mac whose Homebrew is outside the prefix this configuration manages"
  assert_contains "$output" "$foreign/bin/brew" \
    "the preflight does not name the Homebrew it found instead"
  assert_contains "$output" "Nothing has been installed yet" \
    "the preflight does not say that stopping here costs nothing"

  # Refusing at the preflight is what makes it cost nothing: this runs before
  # the Nix install and before step 5, so the prefix must be exactly as it was.
  [ ! -e "$prefix/.managed_by_nix_darwin" ] \
    || fail "the preflight marked the prefix it refused to set up"
  [ ! -e "$prefix/bin" ] \
    || fail "the preflight built out a prefix it refused to set up"

  pass "preflight: a Homebrew outside the managed prefix is named and refused before any password"
}

# --- what is deliberately NOT tested about the prefix -------------------------
#
# Two things, and they should stay visible rather than be papered over.
#
# The `/usr/bin/install -d -o root -g wheel` branch never runs here. It is the
# one thing in this repository that genuinely requires root, it only happens
# when the prefix directory does not exist at all, and exercising it would mean
# running the suite under sudo and creating a directory owned by root on the
# machine running the tests. Every fixture above creates the prefix directory
# first, which is not a contrivance: /usr/local exists on every Mac, so on Intel
# that is the branch a real run takes too.
#
# And nothing here runs `brew`. The bundle step is exercised against a recording
# stand-in, and the generated launcher is read rather than executed: running it
# would use the real prefix baked into it, which is the machine's own
# /opt/homebrew. What the generated launcher SAYS is checked, in
# test_the_generated_brew_is_pinned_to_this_prefix below.

# --- the two implementations of "where is brew" agree -------------------------

# Ask lib/homebrew-present.sh whether a usable Homebrew exists, given a
# HOMEBREW_PREFIX. Prints "found" or "absent".
dotfiles_preflight_verdict() {
  local prefix=$1 answer
  answer=$(HOMEBREW_PREFIX="$prefix" /bin/bash -c \
    '. "$1/lib/homebrew-present.sh"; dotfiles_homebrew_find' _ "$ROOT") \
    || fail "the preflight library failed outright for prefix $prefix"
  if [ -n "$answer" ]; then printf 'found\n'; else printf 'absent\n'; fi
}

# Ask the BUILT activation step the same question, by running it. It finds a
# brew and execs it, or explains and exits non-zero - so its exit status is its
# verdict. The brew it may exec is the stand-in this creates, never a real one.
dotfiles_step_verdict() {
  local prefix=$1 generation script root status=0
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  root=$(dotfiles_test_tmproot dotfiles-agree-home)
  mkdir -p "$root/home/$(dirname "$BREWFILE_TARGET")"
  cp "$generation/home-files/$BREWFILE_TARGET" "$root/home/$BREWFILE_TARGET"

  env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$prefix" \
    "$script" "$prefix" >/dev/null 2>&1 || status=$?

  if [ "$status" = 0 ]; then printf 'found\n'; else printf 'absent\n'; fi
}

test_the_preflight_and_the_step_agree_on_where_brew_is() {
  local root prefix preflight step
  if ! command -v nix >/dev/null 2>&1; then
    skip "preflight/step agreement check (nix not found)"
    return 0
  fi

  # bootstrap.sh answers "is there a Homebrew" up front and the activation step
  # answers it again at the end of a switch. Two implementations of one rule,
  # held together until now by a comment telling the next person to change both.
  # That is what failed: the library fed a space-separated string to an
  # unquoted `for`, so a HOMEBREW_PREFIX containing a space split into two paths
  # that do not exist. bootstrap refused a Mac where the rebuild would have
  # found Homebrew, and the refusal named the path it was sitting at.
  #
  # So the agreement is asserted by running both, not by comparing their text.
  # Each scenario sets up a prefix and asks each side for a verdict; the verdicts
  # have to match, whatever they are.
  #
  # One case is deliberately absent: HOMEBREW_PREFIX unset, which sends both
  # sides to /opt/homebrew and /usr/local. Those are absolute and cannot be
  # redirected, so exercising the step that way on a machine that has Homebrew -
  # every developer machine, every CI runner - would exec the real brew and run
  # a real `bundle install`. That is not a gap worth a real install to close.
  root=$(dotfiles_test_tmproot dotfiles-agreement)

  # A prefix holding a usable brew. The stand-in exits 0, which is what makes
  # running the step safe here.
  prefix="$root/present"
  mkdir -p "$prefix/bin"
  printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/brew"
  chmod +x "$prefix/bin/brew"
  preflight=$(dotfiles_preflight_verdict "$prefix")
  step=$(dotfiles_step_verdict "$prefix")
  assert_eq "$preflight" "found" "the preflight did not find a brew at a prefix that has one"
  assert_eq "$step" "$preflight" \
    "the step and the preflight disagree about a prefix holding a usable brew"

  # A prefix with nothing in it. Both must treat the variable as authoritative
  # and answer "absent" rather than falling back to the standard locations -
  # which this machine has, so a fallback would show up here as "found".
  prefix="$root/empty"
  mkdir -p "$prefix"
  preflight=$(dotfiles_preflight_verdict "$prefix")
  step=$(dotfiles_step_verdict "$prefix")
  assert_eq "$preflight" "absent" \
    "the preflight fell back to a standard location instead of trusting HOMEBREW_PREFIX"
  assert_eq "$step" "$preflight" \
    "the step and the preflight disagree about an empty HOMEBREW_PREFIX"

  # The case that broke: a prefix with a space in it. macOS allows one, and a
  # Mac someone else administers is exactly where a non-standard prefix turns
  # up.
  prefix="$root/my brew"
  mkdir -p "$prefix/bin"
  printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/brew"
  chmod +x "$prefix/bin/brew"
  preflight=$(dotfiles_preflight_verdict "$prefix")
  step=$(dotfiles_step_verdict "$prefix")
  assert_eq "$preflight" "found" \
    "the preflight lost a brew to word splitting on a HOMEBREW_PREFIX containing a space"
  assert_eq "$step" "$preflight" \
    "the step and the preflight disagree about a HOMEBREW_PREFIX containing a space"

  pass "homebrew: the bootstrap preflight and the activation step reach the same verdict"
}

# --- a Mac without Homebrew is told so ----------------------------------------

test_a_missing_homebrew_fails_with_an_explanation() {
  local root generation script output status=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "missing Homebrew check (nix not found)"
    return 0
  fi

  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  root=$(dotfiles_test_tmproot dotfiles-nobrew)
  mkdir -p "$root/home/$(dirname "$BREWFILE_TARGET")" "$root/empty"
  cp "$generation/home-files/$BREWFILE_TARGET" "$root/home/$BREWFILE_TARGET"

  # HOMEBREW_PREFIX naming a directory with no brew in it is how a machine
  # without Homebrew is reproduced on a machine that has one. The step treats
  # the variable as authoritative for exactly this reason.
  output=$(env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$root/empty" \
    "$script" "$root/empty" 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the Homebrew step succeeded on a machine with no Homebrew"

  # The failure has to name this repository and say what to do. A raw "command
  # not found" says neither.
  #
  # What it says has changed with the design, and the assertions with it. It
  # used to send the user to brew.sh, because Homebrew was theirs to install;
  # now Homebrew comes from a pinned flake input and the prefix comes from
  # ./bootstrap.sh, so that is where a machine without one is sent. A test still
  # asserting the old sentence would have been pinning prose that had become
  # wrong.
  assert_contains "$output" "dotfiles-work" \
    "the failure does not say which configuration it came from"
  assert_contains "$output" "./bootstrap.sh" \
    "the failure does not say what to run to get a Homebrew"
  assert_contains "$output" "flake.lock" \
    "the failure does not say that this configuration installs its own Homebrew"
  assert_not_contains "$output" "command not found" \
    "the step let the shell report a missing command instead of explaining"

  pass "homebrew: a Mac without Homebrew gets an explanation and a non-zero exit"
}

# --- the Brewfile never goes to a Homebrew this configuration does not manage -

test_the_homebrew_step_refuses_a_brew_outside_the_managed_prefix() {
  local root generation script output status=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "unmanaged Homebrew check (nix not found)"
    return 0
  fi

  # The second door. bootstrap.sh's preflight refuses a Mac whose Homebrew is
  # somewhere else, but a preflight only runs when someone runs it: a user who
  # adds Homebrew's shellenv line, or a second Homebrew, AFTER a successful
  # setup points HOMEBREW_PREFIX at it, and every later rebuild would hand the
  # whole Brewfile to a Homebrew this configuration does not manage - formulae
  # and casks into someone else's prefix, `--force` replacing apps there, and
  # the prefix the one password paid for left empty. Silently, exit 0.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  root=$(dotfiles_test_tmproot dotfiles-unmanaged)
  mkdir -p "$root/home/$(dirname "$BREWFILE_TARGET")" "$root/managed/bin" "$root/foreign/bin"
  cp "$generation/home-files/$BREWFILE_TARGET" "$root/home/$BREWFILE_TARGET"

  # Both prefixes hold a usable brew, which is what makes this the right
  # scenario rather than the missing-Homebrew one: the step can reach a
  # Homebrew, and still must not use this one. Each records any call, so
  # "installed nothing" is asserted from the absence of a recording rather than
  # from the exit status.
  local standin
  for standin in managed foreign; do
    cat >"$root/$standin/bin/brew" <<STANDIN
#!/bin/sh
printf 'called: %s\n' "\$*" >>"$root/$standin.calls"
STANDIN
    chmod +x "$root/$standin/bin/brew"
  done

  output=$(env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$root/foreign" \
    "$script" "$root/managed" 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the Homebrew step handed the Brewfile to a Homebrew outside the prefix it manages"

  # Nothing ran. This is the assertion the door exists for - a refusal that had
  # already exec'd brew would be a message, not a guard.
  [ ! -e "$root/foreign.calls" ] \
    || fail "the step invoked the unmanaged Homebrew: $(cat "$root/foreign.calls")"
  [ ! -e "$root/managed.calls" ] \
    || fail "the step invoked Homebrew at all after refusing"

  # Both paths named, because "it refused" is not actionable on a Mac with two
  # Homebrews unless the user is told which is which.
  assert_contains "$output" "$root/foreign/bin/brew" \
    "the refusal does not name the Homebrew it found"
  assert_contains "$output" "$root/managed" \
    "the refusal does not name the prefix this configuration manages"
  assert_contains "$output" "dotfiles-work" \
    "the failure does not say which configuration it came from"
  assert_not_contains "$output" "command not found" \
    "the step let the shell report a missing command instead of explaining"

  pass "homebrew: the step refuses a brew outside the prefix it manages, and installs nothing"
}

test_a_trailing_slash_on_homebrew_prefix_is_still_the_managed_homebrew() {
  local root generation script setup binary prefix output status=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "trailing-slash prefix check (nix not found)"
    return 0
  fi

  # `export HOMEBREW_PREFIX=/opt/homebrew/` - what a user writes by hand instead
  # of pasting what `brew shellenv` prints. The kernel collapses the doubled
  # slash that composes into, so the launcher is executable and is plainly the
  # managed one; string equality disagreed, and both doors refused it while
  # printing two spellings of one path as though they were two Homebrews.
  #
  # Asserted as the outcome both doors reach rather than as the shape of the
  # path, because the path is not the contract - "this is ours" is.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  # The Brewfile step: it must proceed, which is only visible as the stand-in
  # being invoked. A refusal here records nothing.
  root=$(dotfiles_test_tmproot dotfiles-trailing)
  mkdir -p "$root/home/$(dirname "$BREWFILE_TARGET")" "$root/prefix/bin"
  cp "$generation/home-files/$BREWFILE_TARGET" "$root/home/$BREWFILE_TARGET"
  cat >"$root/prefix/bin/brew" <<STANDIN
#!/bin/sh
printf 'called: %s\n' "\$*" >>"$root/calls"
STANDIN
  chmod +x "$root/prefix/bin/brew"

  output=$(env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$root/prefix/" \
    "$script" "$root/prefix" 2>&1) || status=$?

  [ "$status" = 0 ] \
    || fail "the Brewfile step refused its own managed Homebrew over a trailing slash: $output"
  [ -e "$root/calls" ] \
    || fail "the Brewfile step installed nothing, so it did not recognise the managed Homebrew"

  # And the preflight, which reaches the same question through the same
  # function. Its fixture needs a launcher that is ours by the state machine's
  # rules too - a symlink into the store - so it borrows the real generated one.
  setup=$(dotfiles_homebrew_prefix_script "$generation") \
    || fail "the activation script does not run a Homebrew prefix-setup step at all"
  binary=$(dotfiles_homebrew_prefix_script_files "$setup" | sed -n 2p)
  [ -x "$binary" ] || fail "the generated brew is not where the setup step says it is"

  prefix=$(dotfiles_fresh_prefix)
  dotfiles_run_initializer "$prefix" >/dev/null \
    || fail "the initializer failed while preparing the fixture"
  ln -shf "$binary" "$prefix/bin/brew"

  status=0
  output=$(dotfiles_run_preflight "$prefix/" "$prefix") || status=$?
  [ "$status" = 0 ] \
    || fail "the preflight refused this Mac's own managed Homebrew over a trailing slash: $output"
  assert_contains "$output" "already set up" \
    "the preflight did not recognise the prefix it was given as the managed one"

  pass "homebrew: a HOMEBREW_PREFIX with a trailing slash is still the managed Homebrew, at both doors"
}

# --- the two answers to "which prefix" agree ----------------------------------

test_the_prefix_the_setup_step_manages_is_this_architectures() {
  local generation setup expected argument searched bundle setup_library bundle_library
  if ! command -v nix >/dev/null 2>&1; then
    skip "prefix agreement check (nix not found)"
    return 0
  fi

  # The prefix is decided twice by construction and must be decided the same way
  # both times: at evaluation, by home.nix, which bakes it into the generated
  # `brew` and into the setup step; and at run time, by
  # lib/homebrew-present.sh, which is what bootstrap.sh asks before Nix exists.
  # Nix reads it off `pkgs.stdenv.hostPlatform`; the shell reads it off
  # `uname -m`. Two mechanisms, one answer, and nothing but this check holding
  # them together.
  #
  # The third party is the Brewfile step, which still searches rather than
  # assuming - it honours HOMEBREW_PREFIX, and that is deliberate, see the
  # comment on dotfiles_homebrew_find. What must be true is that with nothing in
  # the environment, the first place it looks is the prefix the setup step just
  # populated. Otherwise a first switch would set Homebrew up and then fail to
  # find it.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  setup=$(dotfiles_homebrew_prefix_script "$generation") \
    || fail "the activation script does not run a Homebrew prefix-setup step at all"

  expected=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix) \
    || fail "the library could not resolve this Mac's Homebrew prefix"
  assert_contains "$(cat "$setup")" "\"$expected\"" \
    "the built prefix-setup step manages a different prefix than the library reports"

  # The same assertion for the Brewfile step, which needs its own because the
  # two carry the value differently: the setup step has it baked in, and the
  # Brewfile step is handed it on the activate line. That line is the only
  # supplier - the stand-in runs elsewhere in this file pass their own temp
  # prefix, deliberately, so none of them would notice it going missing or
  # turning into the library path.
  argument=$(dotfiles_brew_bundle_argument "$generation") \
    || fail "the activate line does not pass the Brewfile step the prefix it manages, so every switch would stop at it"
  assert_eq "$argument" "$expected" \
    "activation hands the Brewfile step a different prefix than the library reports"

  # And the library's own two answers have to be consistent with each other:
  # /opt/homebrew has its library inside it, /usr/local keeps it one level down.
  if [ "$expected" = /opt/homebrew ]; then
    assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_library)" /opt/homebrew/Library \
      "the Apple silicon library path is not Homebrew's"
  else
    assert_eq "$(dotfiles_homebrew_lib dotfiles_homebrew_library)" /usr/local/Homebrew/Library \
      "the Intel library path is not Homebrew's"
  fi

  # And the Brewfile step, which has to look where the setup step installs. Two
  # assertions, because they fail for different reasons.
  #
  # First: both steps source the SAME library file. That is what makes "one
  # search" a fact rather than a claim - this search used to be written out
  # twice, and the copies drifted.
  bundle=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"
  setup_library=$(sed -n 's|^\. \(/nix/store/[^ ]*\)$|\1|p' "$setup" | head -n1)
  bundle_library=$(sed -n 's|^ *\. \(/nix/store/[^ ]*\)$|\1|p' "$bundle" | head -n1)
  [ -n "$bundle_library" ] \
    || fail "the Brewfile step sources no library, so it has a second copy of the search"
  assert_eq "$bundle_library" "$setup_library" \
    "the Brewfile step and the prefix-setup step source different libraries"

  # Second: with nothing in the environment, the places that library would look
  # include the prefix the setup step populates. Asked by running the function
  # rather than by reading the list out of it.
  # shellcheck disable=SC2016  # $1 is the inner shell's argument, not this one's
  searched=$(env -u HOMEBREW_PREFIX /bin/bash -c \
    '. "$1"; dotfiles_homebrew_searched' _ "$setup_library") \
    || fail "the library could not say where it would look for brew"
  assert_contains "$searched" "$expected/bin/brew" \
    "the Brewfile step would not look where the prefix-setup step installs"

  pass "homebrew: the prefix Nix bakes in, the one the shell resolves, and the one the Brewfile step looks in are the same"
}

test_the_generated_brew_is_pinned_to_this_prefix() {
  local generation setup extra binary content expected version
  if ! command -v nix >/dev/null 2>&1; then
    skip "generated brew check (nix not found)"
    return 0
  fi

  # Read, never run. Running it would use the prefix baked into it, which on
  # this machine is the real /opt/homebrew or /usr/local - so this asserts what
  # the launcher declares, and tests/safety.test.sh asserts that those are the
  # only Homebrew paths in the artifact at all.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  setup=$(dotfiles_homebrew_prefix_script "$generation") \
    || fail "the activation script does not run a Homebrew prefix-setup step at all"
  extra=$(dotfiles_homebrew_prefix_script_files "$setup") \
    || fail "the prefix-setup step names no brew to link"
  binary=$(printf '%s\n' "$extra" | sed -n 2p)
  content=$(cat "$binary")
  expected=$(dotfiles_homebrew_lib dotfiles_homebrew_prefix)

  # The shebang, which must survive unpatched. nix-homebrew's reason, kept
  # because it is still true here: a patched one breaks
  # `arch -x86_64 /usr/local/bin/brew` on Apple silicon. Nothing in the build
  # rewrites it today, so this is a check against a future change that would.
  assert_eq "$(head -n1 "$binary")" "#!/bin/bash" \
    "the generated brew's shebang has been patched, which breaks it under arch -x86_64"

  assert_contains "$content" "export HOMEBREW_PREFIX=\"$expected\"" \
    "the generated brew does not declare this Mac's Homebrew prefix"
  assert_contains "$content" "export HOMEBREW_REPOSITORY=\"\$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix\"" \
    "the generated brew does not point at the repository directory the setup step builds"

  # The whole point of pinning: no auto-update variable in either direction.
  # nix-homebrew sets HOMEBREW_NO_AUTO_UPDATE when it pins taps; this
  # configuration pins no taps and this repository's standing rule is that it
  # never touches that variable at all, because a slow or proxied network is
  # exactly why someone sets it themselves.
  assert_not_contains "$content" "HOMEBREW_NO_AUTO_UPDATE" \
    "the generated brew sets HOMEBREW_NO_AUTO_UPDATE, which is the user's to decide"

  # It has to end in upstream's own exec, which is what proves the tail was
  # spliced in whole rather than truncated.
  assert_contains "$content" "exec /usr/bin/env -i" \
    "the generated brew does not end in the exec upstream's bin/brew ends in"

  # And git has to be on the PATH it hands Homebrew, or every tap operation
  # fails in a way that looks like a network problem.
  assert_contains "$content" "PATH=\"/nix/store/" \
    "the generated brew does not prepend a Nix runtime PATH, so Homebrew would have no git"

  # The version is embedded rather than derived from a git repository that this
  # layout deliberately does not have, and it is the version flake.lock pins.
  version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes"]["brew-src"]["original"]["ref"])' \
    "$ROOT/flake.lock") \
    || fail "could not read the pinned Homebrew version from flake.lock"
  assert_contains "$(cat "$setup")" "brew-$version-patched" \
    "the Homebrew the setup step links is not the version flake.lock pins"

  pass "homebrew: the generated brew is pinned to this prefix, keeps its shebang, and sets no auto-update"
}

# --- nothing is installed twice -----------------------------------------------

# The package names nixpkgs knows the declared packages by, space separated.
dotfiles_nix_pnames() {
  nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\"" \
    --apply 'cfg: builtins.concatStringsSep " " (map (p: p.pname or p.name or "") cfg.config.home.packages)' \
    2>/dev/null
}

# The executables the Nix half actually puts on PATH, space separated, read out
# of the built profile rather than guessed from package names.
dotfiles_nix_executables() {
  local generation=$1
  [ -d "$generation/home-path/bin" ] || return 1
  ( cd "$generation/home-path/bin" && ls ) | tr '\n' ' '
}

# Print the names the Brewfile and the Nix half both provide.
#
# Two comparisons, because the two halves collide in two different ways and
# neither test alone sees both:
#
# - against the nixpkgs package names, normalizing the `-bin` suffix nixpkgs
#   puts on a prebuilt Darwin binary. `ghostty-bin` is the same program as the
#   `ghostty` cask, and this is the comparison that catches a cask, which
#   installs an app rather than anything on PATH;
# - against the executables the Nix half really installs. This is the one that
#   matters for a formula, and it is a comparison rather than a table of name
#   aliases on purpose: nixpkgs calls it `nodejs` and Homebrew calls it `node`,
#   two strings no normalization turns into each other, but both put `node` on
#   PATH - and "two copies on PATH" is the defect itself, not a proxy for it.
#   Anything else spelled differently by the two package managers is caught the
#   same way, without anyone having to maintain a dictionary.
dotfiles_duplicate_collisions() {
  local brewfile=$1 nix_names=$2 nix_bins=$3
  local entry name nix_name nix_bin collisions=""

  while IFS= read -r entry; do
    name=$(printf '%s\n' "$entry" | sed -nE 's/^[[:space:]]*(brew|cask) "([^"]+)".*/\2/p')
    [ -n "$name" ] || continue
    for nix_name in $nix_names; do
      case "${nix_name%-bin}" in
        "$name") collisions="$collisions $name"; continue 2 ;;
      esac
    done
    for nix_bin in $nix_bins; do
      case "$nix_bin" in
        "$name") collisions="$collisions $name"; continue 2 ;;
      esac
    done
  done <"$brewfile"

  printf '%s\n' "$collisions"
}

test_no_tool_is_installed_by_both_nix_and_homebrew() {
  local generation brewfile nix_names nix_bins collisions
  if ! command -v nix >/dev/null 2>&1; then
    skip "duplicate installation check (nix not found)"
    return 0
  fi

  # gh, claude-code, wezterm and ghostty were in home.packages until Homebrew
  # took them over. Leaving them in both would put two builds of each on PATH,
  # and which one answers would come down to the order of a PATH the user did
  # not write - so this is a defect, not a preference, and it is the kind that
  # comes back the next time someone adds a package.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  brewfile="$generation/home-files/$BREWFILE_TARGET"
  [ -f "$brewfile" ] || fail "the generation writes no $BREWFILE_TARGET"

  nix_names=$(dotfiles_nix_pnames) \
    || fail "could not evaluate home.packages"

  nix_bins=$(dotfiles_nix_executables "$generation") \
    || fail "could not list the executables the Nix half installs"

  collisions=$(dotfiles_duplicate_collisions "$brewfile" "$nix_names" "$nix_bins")

  [ -z "$collisions" ] \
    || fail "installed by both Nix and Homebrew, so two copies compete on PATH:$collisions"

  pass "homebrew: no tool is installed by both Nix and Homebrew"
}

test_the_duplicate_guard_catches_a_differently_spelled_collision() {
  local generation nix_names nix_bins root collisions
  if ! command -v nix >/dev/null 2>&1; then
    skip "duplicate detection check (nix not found)"
    return 0
  fi

  # The check above passes by finding nothing, which is also what a guard that
  # cannot see anything does. So the same comparison is run here against a
  # Brewfile that really does collide, and the case chosen is the one this
  # repository's own documentation cites as the reason the rule exists.
  #
  # `node` is the case that matters and the case a name comparison alone gets
  # wrong: nixpkgs calls the package `nodejs`, Homebrew calls the formula
  # `node`, and those two strings never match however they are normalized. What
  # does match is what they put on PATH, which is also the actual defect - so
  # that is what is compared.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  nix_names=$(dotfiles_nix_pnames) \
    || fail "could not evaluate home.packages"
  nix_bins=$(dotfiles_nix_executables "$generation") \
    || fail "could not list the executables the Nix half installs"

  root=$(dotfiles_test_tmproot dotfiles-duplicate-fixture)
  cat >"$root/Brewfile" <<'FIXTURE'
# Someone adds Homebrew's node, not realising nixpkgs already provides it.
brew "node"
brew "gh"
FIXTURE

  collisions=$(dotfiles_duplicate_collisions "$root/Brewfile" "$nix_names" "$nix_bins")

  case " $collisions " in
    *" node "*) : ;;
    *) fail "the duplicate guard missed node against the Nix nodejs, so it would not catch the collision it exists for (got \"$collisions\")" ;;
  esac
  # gh is genuinely absent from the Nix half - it moved to Homebrew - so a guard
  # that flagged it would be matching everything rather than the real thing.
  case " $collisions " in
    *" gh "*) fail "the duplicate guard flagged gh, which Nix does not install - it is matching too much" ;;
  esac

  pass "homebrew: the duplicate guard catches a collision the two package namespaces spell differently"
}

test_brewfile_is_written_inside_the_home_directory
test_brewfile_lists_exactly_the_declared_formulae_and_casks
test_the_homebrew_step_installs_and_cannot_remove
test_the_homebrew_step_does_not_touch_auto_update
test_the_homebrew_step_neutralizes_the_cleanup_variables
test_the_homebrew_step_runs_after_the_brewfile_is_written
test_the_privileged_step_creates_the_prefix_and_marks_it
test_the_privileged_step_does_nothing_the_second_time
test_the_privileged_step_refuses_a_homebrew_it_did_not_install
test_the_privileged_step_refuses_a_prefix_it_cannot_hand_over
test_a_marked_prefix_this_account_cannot_use_is_not_managed
test_a_marked_prefix_that_lost_its_directories_is_refused_before_ln
test_homebrews_own_pruning_does_not_lock_the_prefix
test_the_prefix_setup_step_links_homebrew_without_root
test_the_prefix_setup_step_refuses_a_prefix_bootstrap_has_not_prepared
test_the_prefix_setup_step_refuses_a_homebrew_it_did_not_install
test_the_prefix_state_tells_the_three_cases_apart
test_the_preflight_refuses_a_prefix_that_already_has_a_homebrew
test_the_preflight_accepts_a_mac_with_no_homebrew_and_says_what_it_will_do
test_the_preflight_refuses_a_homebrew_outside_the_managed_prefix
test_the_preflight_and_the_step_agree_on_where_brew_is
test_a_missing_homebrew_fails_with_an_explanation
test_the_homebrew_step_refuses_a_brew_outside_the_managed_prefix
test_a_trailing_slash_on_homebrew_prefix_is_still_the_managed_homebrew
test_the_prefix_the_setup_step_manages_is_this_architectures
test_the_generated_brew_is_pinned_to_this_prefix
test_no_tool_is_installed_by_both_nix_and_homebrew
test_the_duplicate_guard_catches_a_differently_spelled_collision

test_summary
