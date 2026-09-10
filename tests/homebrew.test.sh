#!/usr/bin/env bash
# Behaviour tests for the Homebrew half of this configuration.
#
# This repository drives a Homebrew that the user installed themselves: home.nix
# generates a Brewfile and a Home Manager activation step applies it on every
# switch. That is the one place where this configuration reaches outside the
# home directory, so what it does there is pinned here rather than described in
# prose - README.md and AGENTS.md say what the rules are; these checks are what
# holds the code to them.
#
# Six properties, in order of how much damage getting them wrong would do:
#
# - the step never removes anything, and cannot be talked into it. Homebrew on
#   this machine is the user's own general-purpose package manager, and the
#   setup this repo replaces drove it with `cleanup = "zap"`, which uninstalls
#   whatever the Brewfile does not list. Software installed by hand for
#   unrelated reasons - an employer's security agent included - must survive
#   every rebuild. That means passing no cleanup flag AND refusing the two
#   environment variables that turn a cleanup on without one;
# - the step runs after everything that writes the home directory. Before the
#   Brewfile is written it applies the previous rebuild's package list; before
#   the on-change hooks it can strand the font install permanently, because
#   this is the one step that fails on an otherwise healthy machine;
# - a failed step leaves nothing permanently broken, which is the outcome the
#   ordering exists to protect;
# - a Mac without Homebrew gets an explanation, not `brew: command not found`;
# - nothing is installed by both Nix and Homebrew, because two copies on PATH
#   are decided by an ordering the user never chose;
# - the Brewfile lands inside the home directory, and lists what home.nix says.
#
# The step is exercised by running it, with a recording stand-in for `brew`.
# Asserting on its source text would prove that the words are there; running it
# proves what it does with them. Two checks cannot work that way: the ordering,
# which is a property of the built activate script rather than of the step, and
# the font outcome, which needs a whole activation. Both say so where they sit,
# and the second one is the only place in this suite that activates anything -
# read the comment above it before touching it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 9

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
# Brewfile, because the step refuses to run without one.
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
    "$script" 2>&1 || status=$?

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
  # into a removal, plus `--global`, which is the mode that lets
  # $HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP switch cleanup on from the
  # environment rather than from this repository.
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

# --- a failing Homebrew step leaves nothing permanently broken -----------------
#
# The check above pins the ORDER. This one pins the OUTCOME the order exists to
# protect, by actually activating a configuration and looking at the result.
#
# THIS IS THE ONE PLACE IN THIS SUITE THAT ACTIVATES ANYTHING. AGENTS.md says
# never to activate while testing, and that rule still holds everywhere else -
# `home-manager switch`, ./rebuild.sh and ./bootstrap.sh rewrite a real home
# directory and no test may run them. This is a deliberate, guarded exception,
# and what makes it safe is that it does not activate THIS configuration: it
# builds a variant whose homeDirectory is a temp directory, so every absolute
# path baked into the activate script - the font target, the LaunchAgents
# directory, the profile manifest - points into that temp tree instead of a
# real home. dotfiles_activate_variant refuses to run anything until it has
# confirmed that, by searching the built script for the real home directory and
# finding none. Do not copy this pattern without that guard.
#
# What is being guarded, and it is not hypothetical: the font rsync in
# onFilesChange is the only thing that installs nerd-fonts.hack, and it is
# guarded by a marker file that linkGeneration has already written into the
# home directory. Order the Homebrew step before onFilesChange and a Mac
# without Homebrew aborts activation in between, under `set -eu`, with the
# marker in place and the font never copied. Every later rebuild then compares
# the marker against the store, concludes nothing changed, and skips the rsync
# again. The font never lands and never self-heals; the terminal renders tofu
# and no amount of rebuilding repairs it.
#
# Verified in both directions before this was committed: with the
# "onFilesChange" edge present the font is there at the end, and with that edge
# removed from home.nix the same two runs leave no HomeManager font directory
# at all while the marker sits in place.

# Build the configuration with homeDirectory pointed at $1, and print the store
# path of the resulting generation. Fails, without having run anything, if the
# built script still refers to the real home directory.
dotfiles_activate_variant() {
  local home=$1 repo=$2 built configured
  mkdir -p "$repo"

  # Tracked files only, so the variant is the committed configuration and not
  # whatever else is lying around the working tree.
  (cd "$ROOT" && git ls-files -z | xargs -0 tar -cf -) | (cd "$repo" && tar -xf -) \
    || fail "could not copy the repository into the test root"

  # The repo's own definition of how that line is read and rewritten, rather
  # than a sed of this test's own devising - if it ever stops working, that is
  # something the suite should notice here too.
  /bin/bash -c ". \"\$1/lib/flake-settings.sh\"; flake_settings_set_home_directory \"\$2/flake.nix\" \"\$3\"" \
    _ "$ROOT" "$repo" "$home" \
    || fail "could not point the variant configuration at the test home"

  configured=$(/bin/bash -c ". \"\$1/lib/flake-settings.sh\"; flake_settings_home_directory \"\$2/flake.nix\"" \
    _ "$ROOT" "$repo") \
    || fail "could not read back the variant's homeDirectory"

  # The guard. This repository's whole premise is that it cannot damage a
  # machine it does not administer, and a test that activates a configuration
  # is the one place a bug in the test could break that premise. Both of these
  # must hold before anything runs.
  [ "$configured" = "$home" ] \
    || fail "the variant configuration manages $configured, not the test home $home"
  [ "$configured" != "$HOME" ] \
    || fail "the variant configuration manages the real home directory - refusing to activate"

  built=$(nix build --no-link --print-out-paths "$repo#packages.$SYSTEM.default" 2>/dev/null) \
    || fail "could not build the variant configuration"

  # Belt and braces, and the assertion that actually makes this safe: every
  # absolute path in the activate script is derived from homeDirectory, so if
  # the real home appears anywhere in it, something was not redirected.
  ! grep -q -F "$HOME" "$built/activate" \
    || fail "the variant's activate script still refers to $HOME - refusing to activate"

  printf '%s\n' "$built"
}

# Run a built variant's activate script against a stub `brew` that exits $2.
# Prints nothing; returns the activation's own exit status.
dotfiles_run_activation() {
  local built=$1 home=$2 prefix=$3 brew_exit=$4 nixbin status=0
  nixbin=$(dirname "$(command -v nix)")

  mkdir -p "$prefix/bin"
  printf '#!/bin/sh\nexit %s\n' "$brew_exit" >"$prefix/bin/brew"
  chmod +x "$prefix/bin/brew"

  # env -i for the same reason the stand-in runs use it. USER is needed because
  # the activate script reads it; nix has to be on PATH because installPackages
  # shells out to it, and with HOME inside the temp tree the profile it writes
  # lands there too rather than in the real user's.
  env -i \
    HOME="$home" \
    USER="$(id -un)" \
    PATH="/usr/bin:/bin:$nixbin" \
    HOMEBREW_PREFIX="$prefix" \
    "$built/activate" >"$home/../activation.log" 2>&1 || status=$?

  return "$status"
}

test_a_failed_homebrew_step_still_leaves_the_font_installed() {
  local root home built status=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "font outcome check (nix not found)"
    return 0
  fi

  root=$(dotfiles_test_tmproot dotfiles-fontoutcome)
  home="$root/home"
  mkdir -p "$home"

  built=$(dotfiles_activate_variant "$home" "$root/repo") \
    || fail "could not build a variant configuration to activate"

  # A Mac with no usable Homebrew: the step finds the stub, the stub fails, and
  # activation stops there.
  dotfiles_run_activation "$built" "$home" "$root/prefix" 1 || status=$?
  [ "$status" != 0 ] \
    || fail "the activation succeeded even though the Homebrew step failed"

  # The user installs Homebrew and rebuilds. This must repair the machine.
  dotfiles_run_activation "$built" "$home" "$root/prefix" 0 \
    || fail "the activation failed with a working Homebrew"

  # The outcome, not the order: the font files are on disk.
  [ -d "$home/Library/Fonts/HomeManager" ] \
    || fail "no font was installed after a failed Homebrew step and a successful rebuild - the rsync was stranded behind its marker"
  [ -n "$(find "$home/Library/Fonts/HomeManager" -type f -print -quit)" ] \
    || fail "the font directory was created but is empty after a failed Homebrew step and a successful rebuild"

  pass "homebrew: a failed Homebrew step does not strand the font install"
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
    "$script" 2>&1) || status=$?

  [ "$status" != 0 ] \
    || fail "the Homebrew step succeeded on a machine with no Homebrew"

  # The failure has to name this repository, say what to do, and point at the
  # place Homebrew comes from. A raw "command not found" says none of that.
  assert_contains "$output" "dotfiles-work" \
    "the failure does not say which configuration it came from"
  assert_contains "$output" "https://brew.sh" \
    "the failure does not say where Homebrew comes from"
  assert_contains "$output" "./rebuild.sh" \
    "the failure does not say what to do once Homebrew is installed"
  assert_not_contains "$output" "command not found" \
    "the step let the shell report a missing command instead of explaining"

  pass "homebrew: a Mac without Homebrew gets an explanation and a non-zero exit"
}

# --- nothing is installed twice -----------------------------------------------

test_no_tool_is_installed_by_both_nix_and_homebrew() {
  local generation brewfile nix_names entry name nix_name collisions=""
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

  nix_names=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\"" \
    --apply 'cfg: builtins.concatStringsSep " " (map (p: p.pname or p.name or "") cfg.config.home.packages)' \
    2>/dev/null) \
    || fail "could not evaluate home.packages"

  # nixpkgs suffixes a prebuilt Darwin binary with -bin: `ghostty-bin` is the
  # same program as the `ghostty` cask, and comparing the raw names would miss
  # exactly the collision this repo already had.
  while IFS= read -r entry; do
    name=$(printf '%s\n' "$entry" | sed -nE 's/^[[:space:]]*(brew|cask) "([^"]+)".*/\2/p')
    [ -n "$name" ] || continue
    for nix_name in $nix_names; do
      case "${nix_name%-bin}" in
        "$name") collisions="$collisions $name" ;;
      esac
    done
  done <"$brewfile"

  [ -z "$collisions" ] \
    || fail "installed by both Nix and Homebrew, so two copies compete on PATH:$collisions"

  pass "homebrew: no tool is installed by both Nix and Homebrew"
}

test_brewfile_is_written_inside_the_home_directory
test_brewfile_lists_exactly_the_declared_formulae_and_casks
test_the_homebrew_step_installs_and_cannot_remove
test_the_homebrew_step_does_not_touch_auto_update
test_the_homebrew_step_neutralizes_the_cleanup_variables
test_the_homebrew_step_runs_after_the_brewfile_is_written
test_a_failed_homebrew_step_still_leaves_the_font_installed
test_a_missing_homebrew_fails_with_an_explanation
test_no_tool_is_installed_by_both_nix_and_homebrew

test_summary
