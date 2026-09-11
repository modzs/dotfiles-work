#!/usr/bin/env bash
# Behaviour tests for what this configuration installs from nixpkgs.
#
# Homebrew's half is tests/homebrew.test.sh; nothing appears in both, and that
# is itself asserted there.
#
# Three properties, two of which have already been wrong once:
#
# - every package must exist for BOTH Darwin architectures. `ghostty` in
#   nixpkgs is a Linux-only package; on macOS the working attribute is
#   `ghostty-bin`. Evaluation of an unsupported package fails, so this is
#   caught here rather than on the machine that cannot be repaired;
# - a GUI app from nixpkgs must be symlinked rather than copied, because
#   copying needs a macOS permission that a managed Mac may refuse and whose
#   refusal aborts the whole activation;
# - the font wezterm.lua names by hand is really installed, where macOS looks
#   for it. That one is a link between two files that do not reference each
#   other, and breaking it fails silently: the terminal just renders in some
#   other font.
#
# A third check used to live here: that macOS could resolve an executable
# inside every installed .app bundle. It was written for WezTerm's old-style
# bundle, whose executables sit at the bundle root where a naive path check
# would miss them. It is gone because its subject is gone - WezTerm and Ghostty
# come from Homebrew casks now, which install real applications into
# /Applications, and there is no Nix-installed .app left to probe. If one is
# added, the check is worth restoring from this file's history.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 3

SYSTEM=aarch64-darwin
case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-darwin ;;
esac

# --- every declared package supports both architectures -----------------------

test_every_package_supports_both_architectures() {
  local system unsupported checked=0
  if ! command -v nix >/dev/null 2>&1; then
    skip "package architecture support (nix not found)"
    return 0
  fi

  # meta.platforms is what nixpkgs itself consults, and evaluating
  # home.packages for the other architecture is the only way to learn that a
  # package which builds here does not exist there. Both directions matter:
  # a corporate fleet still hands out Intel Macs.
  for system in aarch64-darwin x86_64-darwin; do
    unsupported=$(nix_eval \
      "homeConfigurations.\"$(dotfiles_config_name "$system")\"" \
      --apply "cfg:
        let
          unsupported = builtins.filter
            (p: !(builtins.elem \"$system\" (p.meta.platforms or [ \"$system\" ])))
            cfg.config.home.packages;
        in builtins.concatStringsSep \" \" (map (p: p.name) unsupported)" \
      2>/dev/null) \
      || fail "could not evaluate home.packages for $system"
    [ -z "$unsupported" ] \
      || fail "these packages do not support $system: $unsupported"
    checked=$((checked + 1))
  done

  assert_eq "$checked" 2 "both architectures should have been checked"

  pass "packages: every declared package supports aarch64-darwin and x86_64-darwin"
}

# --- GUI apps are linked, not copied ------------------------------------------

test_gui_apps_are_linked_rather_than_copied() {
  local link copy
  if ! command -v nix >/dev/null 2>&1; then
    skip "GUI app installation mode (nix not found)"
    return 0
  fi

  # A deliberate departure from the Home Manager default for stateVersion
  # 25.11 and later. `copyApps` rsyncs the bundles so Spotlight indexes them,
  # but it needs the macOS App Management permission, and when it cannot get it
  # it resets that TCC service and aborts the whole activation. On a machine
  # whose privacy settings someone else administers, that permission may not be
  # grantable at all - and losing the entire switch over two terminal emulators
  # is the wrong trade. See home.nix and README.md.
  link=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".config.targets.darwin.linkApps.enable" \
    --apply 'v: if v then "true" else "false"' 2>/dev/null) \
    || fail "could not evaluate targets.darwin.linkApps.enable"
  copy=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".config.targets.darwin.copyApps.enable" \
    --apply 'v: if v then "true" else "false"' 2>/dev/null) \
    || fail "could not evaluate targets.darwin.copyApps.enable"

  assert_eq "$link" true "GUI apps should be symlinked into ~/Applications"
  assert_eq "$copy" false \
    "GUI apps must not be copied: copyApps needs the App Management permission and aborts activation without it"

  pass "packages: GUI apps are symlinked into ~/Applications, needing no macOS permission"
}

# --- the font wezterm names actually lands ------------------------------------

test_the_configured_font_is_installed_where_wezterm_looks() {
  local generation fonts line destination family file nerdfonts candidate found
  if ! command -v nix >/dev/null 2>&1; then
    skip "the configured font (nix not found)"
    return 0
  fi

  # home.nix calls nerd-fonts.hack "the font everything renders in" and
  # wezterm.lua hard-codes the family by name. Nothing connected the two: a
  # rename on either side would leave wezterm asking for a font that is not
  # there, and the only symptom is a terminal quietly falling back to another
  # one. Asked of the built artifact rather than of a real activation, because
  # nothing in this suite may activate - see tests/homebrew.test.sh.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package for $SYSTEM"

  fonts=$(grep -o '/nix/store/[a-z0-9]*-home-manager-fonts/share/fonts/' \
    "$generation/activate" | head -n1)
  [ -n "$fonts" ] || fail "the activation script installs no fonts at all"

  # The rsync destination is the tail of the same line, and it is what
  # wezterm's font lookup will search.
  line=$(grep -m1 -F "$fonts" "$generation/activate")
  destination=${line##* }
  case $destination in
    */Library/Fonts/HomeManager) : ;;
    *) fail "the font is installed to $destination, which macOS does not search for fonts" ;;
  esac

  family=$(sed -nE 's/^config\.font = wezterm\.font\("([^"]*)"\).*/\1/p' \
    "$ROOT/home/.config/wezterm/wezterm.lua")
  [ -n "$family" ] || fail "could not read the font family out of wezterm.lua"

  # Nerd Fonts name their files after the family with the spaces removed. Which
  # subdirectory the family lands in is Home Manager's layout, not a promise of
  # this repository's, so it is searched rather than named: naming it would make
  # a font changed correctly on both sides fail as though the link were broken.
  file=$(printf '%s\n' "$family" | tr -d ' ')
  nerdfonts="$fonts/truetype/NerdFonts"
  [ -d "$nerdfonts" ] \
    || fail "no $nerdfonts directory: the font layout moved, so this check no longer knows where to look"

  found=''
  for candidate in "$nerdfonts"/*/"$file-Regular.ttf"; do
    [ -f "$candidate" ] || continue
    found=$candidate
    break
  done
  [ -n "$found" ] \
    || fail "wezterm.lua asks for \"$family\", but no $file-Regular.ttf is installed under $nerdfonts"

  pass "packages: the font wezterm.lua names is installed into $destination"
}

test_every_package_supports_both_architectures
test_gui_apps_are_linked_rather_than_copied
test_the_configured_font_is_installed_where_wezterm_looks

test_summary
