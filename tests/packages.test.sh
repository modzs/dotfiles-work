#!/usr/bin/env bash
# Behaviour tests for what this configuration installs from nixpkgs.
#
# Homebrew's half is tests/homebrew.test.sh; nothing appears in both, and that
# is itself asserted there.
#
# Two properties, both of which have already been wrong once:
#
# - every package must exist for BOTH Darwin architectures. `ghostty` in
#   nixpkgs is a Linux-only package; on macOS the working attribute is
#   `ghostty-bin`. Evaluation of an unsupported package fails, so this is
#   caught here rather than on the machine that cannot be repaired;
# - a GUI app from nixpkgs must be symlinked rather than copied, because
#   copying needs a macOS permission that a managed Mac may refuse and whose
#   refusal aborts the whole activation.
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
dotfiles_test_expect 2

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

test_every_package_supports_both_architectures
test_gui_apps_are_linked_rather_than_copied

test_summary
