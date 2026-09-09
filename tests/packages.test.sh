#!/usr/bin/env bash
# Behaviour tests for what this configuration actually installs.
#
# Two properties, both of which have already been wrong once:
#
# - every package must exist for BOTH Darwin architectures. `ghostty` in
#   nixpkgs is a Linux-only package; on macOS the working attribute is
#   `ghostty-bin`. Evaluation of an unsupported package fails, so this is
#   caught here rather than on the machine that cannot be repaired;
# - the two GUI apps must end up somewhere macOS will actually launch them.
#   Home Manager's Darwin default changed at stateVersion 25.11, and a
#   .app whose executable macOS cannot resolve is a bundle that looks
#   installed and is not.
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

# --- the app bundles are ones macOS can launch --------------------------------

test_gui_app_bundles_resolve_an_executable() {
  local generation apps probe report
  if ! command -v nix >/dev/null 2>&1; then
    skip "GUI app bundle check (nix not found)"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    skip "GUI app bundle check (python3 not found)"
    return 0
  fi
  if [ "$(uname -s)" != Darwin ]; then
    skip "GUI app bundle check (not macOS)"
    return 0
  fi

  # The built generation, because the question is about the artifact, not the
  # source. This is the same derivation CI builds, so it is already in the
  # store by the time the suite runs.
  generation=$(nix build --no-link --print-out-paths "$ROOT#packages.$SYSTEM.default" 2>/dev/null) \
    || fail "could not build the activation package"
  apps="$generation/home-files/Applications/Home Manager Apps"
  [ -d "$apps" ] \
    || fail "the generation installs no ~/Applications/Home Manager Apps directory"

  for name in WezTerm.app Ghostty.app; do
    [ -e "$apps/$name" ] || fail "$name is not installed into ~/Applications"
  done

  probe=$(mktemp "${TMPDIR:-/tmp}/dotfiles-bundleprobe.XXXXXX") \
    || fail "could not create a temp file for the bundle probe"
  cat >"$probe" <<'PY'
# Ask macOS's own bundle loader where each app bundle's executable is. This
# resolves the bundle; it does not launch anything.
#
# It is not enough to check that Contents/MacOS/<name> exists: WezTerm ships an
# old-style bundle with its executables at the bundle root, which CoreFoundation
# accepts and a hand-rolled path check would wrongly reject. Asking
# CoreFoundation is asking the component that really decides.
import ctypes, ctypes.util, sys

CF = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFURLCreateWithFileSystemPath.restype = ctypes.c_void_p
CF.CFURLCreateWithFileSystemPath.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_bool]
CF.CFBundleCreate.restype = ctypes.c_void_p
CF.CFBundleCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
CF.CFBundleCopyExecutableURL.restype = ctypes.c_void_p
CF.CFBundleCopyExecutableURL.argtypes = [ctypes.c_void_p]
CF.CFURLCopyFileSystemPath.restype = ctypes.c_void_p
CF.CFURLCopyFileSystemPath.argtypes = [ctypes.c_void_p, ctypes.c_long]
CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]

UTF8 = 0x08000100
POSIX = 0

def cfstr(value):
    return CF.CFStringCreateWithCString(None, value.encode(), UTF8)

problems = []
for path in sys.argv[1:]:
    url = CF.CFURLCreateWithFileSystemPath(None, cfstr(path), POSIX, True)
    bundle = CF.CFBundleCreate(None, url)
    if not bundle:
        problems.append("%s: macOS does not recognize this as an app bundle" % path)
        continue
    if not CF.CFBundleCopyExecutableURL(bundle):
        problems.append("%s: bundle loads but macOS resolves no executable in it" % path)

print("\n".join(problems))
PY

  report=$(python3 "$probe" "$apps/WezTerm.app" "$apps/Ghostty.app")
  rm -f "$probe"
  [ -z "$report" ] || fail "$report"

  pass "packages: macOS resolves an executable in every installed .app bundle"
}

test_every_package_supports_both_architectures
test_gui_apps_are_linked_rather_than_copied
test_gui_app_bundles_resolve_an_executable

test_summary
