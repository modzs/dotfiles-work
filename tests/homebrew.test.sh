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
# Four properties, in order of how much damage getting them wrong would do:
#
# - the step never removes anything. Homebrew on this machine is the user's own
#   general-purpose package manager, and the setup this repo replaces drove it
#   with `cleanup = "zap"`, which uninstalls whatever the Brewfile does not
#   list. Software installed by hand for unrelated reasons - an employer's
#   security agent included - must survive every rebuild;
# - a Mac without Homebrew gets an explanation, not `brew: command not found`;
# - nothing is installed by both Nix and Homebrew, because two copies on PATH
#   are decided by an ordering the user never chose;
# - the Brewfile lands inside the home directory, and lists what home.nix says.
#
# The step is exercised by running it, with a recording stand-in for `brew`.
# Asserting on its source text would prove that the words are there; running it
# proves what it does with them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 6

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

  # Not one of the paths `brew bundle --global` reads. --global is also the
  # mode in which $HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP turns on an unprompted
  # cleanup, so a Brewfile sitting on that search path could be turned into an
  # uninstaller by a command run for some entirely unrelated reason.
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
STANDIN
  chmod +x "$root/prefix/bin/brew"

  # env -i, so the recording reflects what the step sets rather than what the
  # shell running the suite happened to export. PATH is deliberately useless:
  # Home Manager's activation replaces PATH before running this, and the step
  # has to find Homebrew without it.
  env -i \
    HOME="$root/home" \
    PATH=/usr/bin:/bin \
    HOMEBREW_PREFIX="$root/prefix" \
    HOMEBREW_NO_AUTO_UPDATE=1 \
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

  assert_eq "$argv" "bundle install --file $home/$BREWFILE_TARGET --force" \
    "the Homebrew step does not run \`brew bundle install --file <Brewfile> --force\`"

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

  pass "homebrew: the step runs \`brew bundle install\` and passes nothing that can uninstall"
}

test_the_homebrew_step_leaves_auto_update_on() {
  local recording
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew auto-update check (nix not found)"
    return 0
  fi

  # The equivalent of nix-darwin's `onActivation.autoUpdate = true`, which is
  # what the personal configuration this mirrors sets. Homebrew reads
  # HOMEBREW_NO_AUTO_UPDATE as a flag - any value at all, "0" included, turns
  # auto-update off - so the only way to leave it on is to unset the variable,
  # and the stand-in is handed HOMEBREW_NO_AUTO_UPDATE=1 to prove the step
  # really does.
  recording=$(dotfiles_run_brew_step) \
    || fail "could not run the Homebrew step against a stand-in brew"

  assert_contains "$recording" "HOMEBREW_NO_AUTO_UPDATE: <unset>" \
    "the Homebrew step leaves HOMEBREW_NO_AUTO_UPDATE set, which turns auto-update off"

  pass "homebrew: the step unsets HOMEBREW_NO_AUTO_UPDATE, leaving auto-update on"
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
test_the_homebrew_step_leaves_auto_update_on
test_a_missing_homebrew_fails_with_an_explanation
test_no_tool_is_installed_by_both_nix_and_homebrew

test_summary
