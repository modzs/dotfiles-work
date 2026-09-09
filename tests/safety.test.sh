#!/usr/bin/env bash
# The design rule, made executable.
#
# This repository exists for one reason: nothing it does may affect anything
# outside the user's home directory. Every check here asserts a piece of that
# rule against the artifact that really decides it, not against the prose in
# README.md:
#
# - flake.lock, because that is the complete, machine-written record of every
#   flake this configuration pulls in - including one added indirectly, which a
#   grep over flake.nix would never see;
# - the evaluated option tree, because an option that does not exist cannot be
#   set. Standalone Home Manager has no `networking`, no `system.defaults`, no
#   `homebrew` and no `users`, and this proves that is still true rather than
#   trusting it;
# - the evaluated file targets, because a relative target is by definition
#   inside $HOME and an absolute one is by definition not;
# - a real shell tokenizer over every tracked script, because `sudo` written in
#   a comment and `sudo` written as a command are not the same thing, and a
#   grep cannot tell them apart in either direction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

SYSTEM=aarch64-darwin
case "$(uname -m)" in
  x86_64) SYSTEM=x86_64-darwin ;;
esac

# --- the flake pulls in nothing that can configure a system -------------------

test_flake_pulls_in_no_system_configuration_tool() {
  local report
  if ! command -v python3 >/dev/null 2>&1; then
    skip "flake input check (python3 not found)"
    return 0
  fi

  # flake.lock is parsed as JSON rather than scanned as text, and every node in
  # the graph is inspected - not just the root's direct inputs. An input that
  # arrived through some other flake is exactly the case a text search misses.
  report=$(python3 - "$ROOT/flake.lock" <<'PY'
import json, sys

BANNED = ("nix-darwin", "darwin", "nix-homebrew", "brew", "homebrew")
EXPECTED_ROOT_INPUTS = {"home-manager", "nixpkgs"}

with open(sys.argv[1]) as fh:
    lock = json.load(fh)

nodes = lock["nodes"]
problems = []

root_inputs = set(nodes[lock["root"]]["inputs"])
if root_inputs != EXPECTED_ROOT_INPUTS:
    problems.append(
        "flake.nix declares inputs %s, expected exactly %s"
        % (sorted(root_inputs), sorted(EXPECTED_ROOT_INPUTS))
    )

for name, node in nodes.items():
    if name == lock["root"]:
        continue
    locked = node.get("locked", {})
    original = node.get("original", {})
    fields = [
        str(locked.get("repo", "")),
        str(locked.get("owner", "")),
        str(locked.get("url", "")),
        str(original.get("repo", "")),
        str(original.get("owner", "")),
        str(original.get("url", "")),
    ]
    haystack = " ".join(fields).lower()
    for banned in BANNED:
        if banned in haystack:
            problems.append(
                "locked input %r resolves to %r, which matches the banned name %r"
                % (name, " ".join(f for f in fields if f), banned)
            )
            break

print("\n".join(problems))
PY
  ) || fail "could not parse flake.lock"

  [ -z "$report" ] || fail "flake.lock pulls in a system-configuration tool: $report"

  pass "flake: the locked input graph is nixpkgs and home-manager, and nothing else"
}

# --- the configuration cannot express system settings -------------------------

test_configuration_has_no_system_level_options() {
  local present
  if ! command -v nix >/dev/null 2>&1; then
    skip "system-level option check (nix not found)"
    return 0
  fi

  # Asking the evaluated option tree, not the source. Every namespace below
  # belongs to nix-darwin; in a standalone Home Manager configuration they must
  # not exist at all, so `system.defaults`, `networking.hostName`,
  # `homebrew.casks` and `users.users` are not merely unset - they are
  # unsettable. `launchd` and `services` are deliberately absent from the list:
  # Home Manager defines those itself and they write per-user agents into
  # ~/Library/LaunchAgents, which is inside the home directory.
  present=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".options" \
    --apply 'o:
      let banned = [ "networking" "system" "homebrew" "nix-homebrew" "users" "security" "environment" "power" ];
      in builtins.concatStringsSep " " (builtins.filter (n: builtins.hasAttr n o) banned)' \
    2>/dev/null) \
    || fail "could not evaluate the configuration's option tree"

  [ -z "$present" ] \
    || fail "the configuration defines system-level option namespaces: $present - a nix-darwin module has been mixed in"

  pass "config: no system-level option namespace exists, so none can be set"
}

# --- every managed file lands inside the home directory -----------------------

test_every_managed_file_target_is_inside_home() {
  local escaping
  if ! command -v nix >/dev/null 2>&1; then
    skip "managed file target check (nix not found)"
    return 0
  fi

  # Home Manager states every target relative to the home directory. An
  # absolute target, or one climbing out with "..", is the only way a managed
  # file could land somewhere else - so those are what this looks for, in the
  # evaluated configuration rather than in the source that produced it.
  escaping=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".config.home.file" \
    --apply 'files:
      let
        targets = map (f: f.target) (builtins.attrValues files);
        parts = t: builtins.filter builtins.isString (builtins.split "/" t);
        escapes = t: builtins.substring 0 1 t == "/" || builtins.elem ".." (parts t);
      in builtins.concatStringsSep " " (builtins.filter escapes targets)' \
    2>/dev/null) \
    || fail "could not evaluate the configuration's managed files"

  [ -z "$escaping" ] \
    || fail "these managed files target a path outside the home directory: $escaping"

  pass "config: every managed file target is relative, so every one is inside \$HOME"
}

# --- the home directory is the one flake.nix declares -------------------------

test_home_directory_matches_the_declared_one() {
  local declared evaluated
  if ! command -v nix >/dev/null 2>&1; then
    skip "home directory check (nix not found)"
    return 0
  fi

  # shellcheck source=lib/flake-settings.sh
  . "$ROOT/lib/flake-settings.sh"
  declared=$(flake_settings_home_directory "$ROOT/flake.nix") \
    || fail "could not read the configured home directory from flake.nix"

  evaluated=$(nix_eval \
    "homeConfigurations.\"$(dotfiles_config_name "$SYSTEM")\".config.home.homeDirectory" \
    2>/dev/null) \
    || fail "could not evaluate the configuration's home directory"

  assert_eq "$evaluated" "$declared" \
    "the configuration manages a different home directory than flake.nix declares"

  pass "config: the managed home directory is the one flake.nix declares ($declared)"
}

# --- no script in this repo can ask for elevated privileges -------------------

test_no_tracked_script_escalates_privileges() {
  local script report status=0
  if ! command -v python3 >/dev/null 2>&1; then
    skip "privilege escalation check (python3 not found)"
    return 0
  fi

  # A real shell tokenizer, so a word inside a comment is not mistaken for a
  # command and a command is not missed because of the spacing around it. The
  # rebuild path must never prompt for a password: the whole promise of this
  # repo is that it is usable on a machine the user does not administer.
  #
  # The tokenizer goes into a temp file rather than onto python's stdin,
  # because stdin is already spoken for - it is where xargs reads the file list.
  script=$(mktemp "${TMPDIR:-/tmp}/dotfiles-tokenize.XXXXXX") \
    || fail "could not create a temp file for the tokenizer"
  cat >"$script" <<'PY'
import shlex, sys

# Every macOS way of running something as another user, plus the AppleScript
# spelling that raises an authorization dialog.
BANNED = {"sudo", "doas", "su", "sudoedit", "pkexec"}
APPLESCRIPT = "with administrator privileges"

problems = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    lexer = shlex.shlex(source, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError as error:
        problems.append("%s: could not be tokenized (%s)" % (path, error))
        continue
    for token in tokens:
        if token in BANNED:
            problems.append("%s: runs %r" % (path, token))
    if APPLESCRIPT in source.lower():
        problems.append("%s: contains %r" % (path, APPLESCRIPT))

print("\n".join(problems))
PY

  # This file excludes itself: it has to spell out the words it forbids in
  # order to look for them.
  report=$(dotfiles_tracked_except "$(dotfiles_test_self)" '*.sh' \
    | xargs -0 python3 "$script") || status=$?
  rm -f "$script"
  [ "$status" = 0 ] || fail "could not tokenize the tracked shell scripts"

  [ -z "$report" ] \
    || fail "a tracked script escalates privileges: $report"

  pass "scripts: no tracked shell script runs sudo or any other privilege escalation"
}

# --- nothing that executes here knows about Homebrew --------------------------

test_nothing_executable_references_homebrew() {
  local generation hits
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew path check (nix not found)"
    return 0
  fi

  # Homebrew is a system-wide package manager rooted outside the home
  # directory, and the setup this repo replaces drove it with
  # `cleanup = "zap"`, which uninstalls anything not listed - a security agent
  # installed by an employer's IT included. Nothing that runs here may grow a
  # path into it or a call to it.
  #
  # This checks the built artifact - the activation package including the
  # activate script, home-files tree, and profile - not source code. A reference
  # in source that is dead code or in a comment is not a problem; a reference
  # in the generated activation bundle would cause the configuration to fail
  # on a machine that has no Homebrew installed.
  generation=$(nix build --no-link --print-out-paths "$ROOT#packages.$SYSTEM.default" 2>/dev/null) \
    || fail "could not build the activation package"

  hits=$(grep -r -E '/opt/homebrew|/usr/local/Homebrew' "$generation" 2>/dev/null || true)

  [ -z "$hits" ] \
    || fail "the built activation package contains Homebrew paths: $hits"

  pass "artifact: the activation package contains no Homebrew paths"
}

test_flake_pulls_in_no_system_configuration_tool
test_configuration_has_no_system_level_options
test_every_managed_file_target_is_inside_home
test_home_directory_matches_the_declared_one
test_no_tracked_script_escalates_privileges
test_nothing_executable_references_homebrew

test_summary
