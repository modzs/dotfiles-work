#!/usr/bin/env bash
# The design rule, made executable.
#
# The rule this repository exists for is that it must not reconfigure a Mac the
# user does not administer. It used to be stated as "nothing it does may affect
# anything outside the user's home directory", and every check here enforced
# that literally.
#
# That is no longer the whole truth, and this file says so out loud rather than
# quietly enforcing less. On the user's instruction this configuration now
# drives Homebrew: it generates a Brewfile and asks an existing Homebrew to
# install what it lists, which writes into /opt/homebrew and puts casks in
# /Applications. So the rule has narrowed, deliberately and in exactly one
# place - see AGENTS.md and README.md, which state the narrowed version in the
# same words - and the checks below have narrowed with it:
#
# - test_nothing_here_installs_homebrew and
#   test_the_only_homebrew_paths_are_the_two_prefixes replace a single check
#   that asserted the built artifact contained no Homebrew path at all. What
#   still holds is that this repo never installs, updates or removes Homebrew
#   itself, and that the only Homebrew paths it embeds are the two it needs to
#   find an existing `brew`. What it does with that `brew` - install, never
#   uninstall - is exercised by running it, in tests/homebrew.test.sh.
#
# Nothing else changed. Every other check below is the original one: no
# nix-darwin, no system-level options, no managed file outside $HOME, no
# privilege escalation anywhere in this repo's own scripts.
#
# Each check asserts against the artifact that really decides it, not against
# the prose in README.md:
#
# - flake.lock, because that is the complete, machine-written record of every
#   flake this configuration pulls in - including one added indirectly, which a
#   grep over flake.nix would never see;
# - the evaluated option tree, because an option that does not exist cannot be
#   set. Standalone Home Manager has no `networking`, no `system.defaults`, no
#   `homebrew` and no `users`, and this proves that is still true rather than
#   trusting it. The Homebrew step is a Home Manager activation script, not a
#   nix-darwin module, so it does not and must not make any of those settable;
# - the evaluated file targets, because a relative target is by definition
#   inside $HOME and an absolute one is by definition not;
# - a real shell tokenizer over every tracked script, because `sudo` written in
#   a comment and `sudo` written as a command are not the same thing, and a
#   grep cannot tell them apart in either direction.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# Every check this file must account for. test_summary fails if the number
# that actually ran differs, so a check lost to a broken helper cannot show up
# as a smaller, healthy-looking "ok" total. Move this when you add a test.
dotfiles_test_expect 8

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

# Write the Homebrew-invocation scanner to a temp file and print its path.
# Split out from its caller so the checker itself can be run against fixture
# scripts whose answer is known - a scanner that has never been shown a real
# invocation is a scanner nobody has tested.
dotfiles_write_brewscan() {
  local script
  script=$(mktemp "${TMPDIR:-/tmp}/dotfiles-brewscan.XXXXXX") \
    || fail "could not create a temp file for the tokenizer"
  cat >"$script" <<'SCAN'
import shlex, sys

# The contract is that no script this repo runs may INVOKE Homebrew. Naming its
# path is a different act and a legitimate one: lib/homebrew-present.sh has to
# ask whether /opt/homebrew/bin/brew exists, because bootstrap.sh must turn a
# Mac without Homebrew away before it installs Nix. A check that cannot tell
# `[ -x /opt/homebrew/bin/brew ]` from running brew was asserting the wrong
# thing, so this one looks at POSITION: a token whose basename is `brew` is a
# problem when it is the command word, and unremarkable when it is an argument.
#
# An explicit separator token is inserted after each newline first. shlex treats
# a newline as ordinary whitespace, so without this the first word of every line
# would look like an argument to the line before it and a `brew install` on its
# own line would be missed entirely.
#
# The newline itself is KEPT, and that is not incidental: shlex ends a comment
# at a newline, so replacing newlines rather than following them makes the first
# `#` in a file swallow the whole file as one comment. That yields zero tokens
# and a scanner that cheerfully passes anything - which is exactly what happened
# here, and why the fixture check below exists.
BANNED = {"brew"}
# What can precede a command word. `in` is deliberately absent: in `for x in
# LIST` and `case x in` what follows is a word list, so treating it as a
# separator would flag the path-existence loop this check exists to permit.
SEPARATORS = {
    "\n", ";", ";;", "|", "||", "&", "&&", "(", ")", "{", "}",
    "then", "else", "elif", "do", "!", "time",
}
INSTALLERS = (
    "raw.githubusercontent.com/homebrew",
    "homebrew/install",
    "github.com/homebrew/brew",
)

NEWLINE = "\x00NL\x00"

problems = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    lexer = shlex.shlex(source.replace("\n", "\n %s " % NEWLINE),
                        posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = [("\n" if t == NEWLINE else t) for t in lexer]
    except ValueError as error:
        problems.append("%s: could not be tokenized (%s)" % (path, error))
        continue
    previous = "\n"
    for token in tokens:
        if token.rsplit("/", 1)[-1] in BANNED and previous in SEPARATORS:
            problems.append("%s: runs %r" % (path, token))
        previous = token
    lowered = source.lower()
    for installer in INSTALLERS:
        if installer in lowered:
            problems.append("%s: names the Homebrew installer (%r)" % (path, installer))

print("\n".join(problems))
SCAN

  printf '%s\n' "$script"
}

# --- nothing here installs, updates or removes Homebrew itself ----------------

test_nothing_here_installs_homebrew() {
  local script report status=0
  if ! command -v python3 >/dev/null 2>&1; then
    skip "Homebrew installer check (python3 not found)"
    return 0
  fi

  # The narrowed rule, first half. This configuration drives a Homebrew the
  # user installed themselves, and installing Homebrew is a different act
  # entirely: its installer asks for a password and writes to /opt or
  # /usr/local. On a machine someone else administers that is not this repo's
  # decision to make, so it must not be able to make it - and `brew update`
  # against Homebrew's own installation, or `brew uninstall` against something
  # it manages, are the same kind of act in the other direction.
  #
  # Scoped to the scripts a user runs - bootstrap.sh, rebuild.sh and the
  # libraries they source, which between them are every line of shell this repo
  # executes on a real machine. A convenience like "let me just install it for
  # you" would appear there. The single place this repo may call `brew` is
  # home.nix's activation step, and what that step does is exercised by running
  # it in tests/homebrew.test.sh.
  #
  # Tokenized rather than grepped, for the same reason the sudo check above is:
  # these scripts have to be free to *explain* Homebrew in a comment, and a
  # word in a comment is not a command.
  #
  # The rule is INVOCATION, not mention, and the distinction is load bearing
  # rather than pedantic: lib/homebrew-present.sh has to test whether
  # /opt/homebrew/bin/brew exists so bootstrap.sh can turn a Mac without
  # Homebrew away before installing Nix. Asking whether a path exists is not
  # running the program at it, and a check that conflated the two would have
  # forced that preflight to be written obscurely to get past its own suite.
  # test_the_homebrew_scan_tells_an_invocation_from_a_path_test proves the
  # narrowed rule still catches the thing it is for.
  #
  # This does read implementation source, and that has been raised and settled.
  # It is not the anti-pattern the rest of this suite avoids, and the line
  # between them is what the source is being asked to stand for. A test that
  # greps README.md or HOW-TO.md would be using text as a proxy for behaviour -
  # prose is not a contract, and pinning its wording proves nothing about
  # whether it is true. This file enforces a design rule about what this
  # repository's own code may *contain*, so here the source is the contract
  # itself, not evidence about something else. That is why the pre-existing
  # sudo check above already works this way, and why both go through a real
  # shell tokenizer instead of a grep.
  script=$(dotfiles_write_brewscan) \
    || fail "could not write the Homebrew-invocation scanner"

  report=$(dotfiles_tracked_except "$(dotfiles_test_self)" \
    bootstrap.sh rebuild.sh 'lib/*.sh' \
    | xargs -0 python3 "$script") || status=$?
  rm -f "$script"
  [ "$status" = 0 ] || fail "could not tokenize the scripts this repo runs"

  [ -z "$report" ] \
    || fail "a script this repo runs reaches for Homebrew, which only home.nix may: $report"

  pass "scripts: nothing here installs, updates or removes Homebrew itself"
}

test_the_homebrew_scan_tells_an_invocation_from_a_path_test() {
  local script root report status=0
  if ! command -v python3 >/dev/null 2>&1; then
    skip "Homebrew scanner behaviour check (python3 not found)"
    return 0
  fi

  # The check above passes when it finds nothing, which is also what a broken
  # scanner does. So the scanner is run here against two fixtures whose answer
  # is known in advance: one that really invokes Homebrew and must be flagged,
  # one that only asks whether its path exists and must not be. Without this,
  # narrowing the rule could have quietly turned the check into a no-op and the
  # suite would have gone on printing ok.
  script=$(dotfiles_write_brewscan) \
    || fail "could not write the Homebrew-invocation scanner"
  root=$(dotfiles_test_tmproot dotfiles-brewscan-fixtures)

  cat >"$root/invokes.sh" <<'FIXTURE'
#!/usr/bin/env bash
# A convenience someone might add: install the prerequisite for the user.
if ! command -v nix >/dev/null 2>&1; then
  brew install nix
fi
/opt/homebrew/bin/brew bundle install --file "$HOME/Brewfile"
FIXTURE

  cat >"$root/probes.sh" <<'FIXTURE'
#!/usr/bin/env bash
# What lib/homebrew-present.sh does: a path question, never a command.
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
done
FIXTURE

  report=$(python3 "$script" "$root/invokes.sh") || status=$?
  [ "$status" = 0 ] || fail "the scanner could not tokenize the invoking fixture"
  assert_contains "$report" "invokes.sh" \
    "the scanner did not flag a script that runs \`brew install\` - it would pass anything"
  # Both spellings, because a bare command word and an absolute path in command
  # position are the two ways this could arrive.
  assert_contains "$report" "'brew'" \
    "the scanner did not flag a bare \`brew\` command word"
  assert_contains "$report" "'/opt/homebrew/bin/brew'" \
    "the scanner did not flag an absolute brew path used as a command"

  report=$(python3 "$script" "$root/probes.sh") || status=$?
  rm -f "$script"
  [ "$status" = 0 ] || fail "the scanner could not tokenize the probing fixture"
  [ -z "$report" ] \
    || fail "the scanner flagged a path existence test as an invocation: $report"

  pass "scripts: the Homebrew scan flags an invocation and allows a path test"
}

# --- the only Homebrew the artifact knows about is an existing one ------------

test_the_only_homebrew_paths_are_the_two_prefixes() {
  local generation script hit hits unexpected=""
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew path check (nix not found)"
    return 0
  fi

  # The narrowed rule, second half, and the check this file used to make in its
  # absolute form: the built activation package contained no Homebrew path at
  # all. It now contains two, because finding an existing `brew` is the whole
  # mechanism - Home Manager replaces PATH with Nix store paths before running
  # an activation script, so an absolute probe is the only way left.
  #
  # Two, and no more. A third would mean something here had started reaching
  # into Homebrew's own tree - its Cellar, its Library, its repository - rather
  # than just asking its `brew` to install a Brewfile.
  #
  # This checks the built artifact, not the source: a path in a comment is not
  # a path the machine follows. Three things are in scope - the activate script,
  # the generated home-files tree, and the Homebrew step, which is its own store
  # path referenced from the activate script rather than a file inside the
  # generation.
  #
  # Enumerated with `find -L` rather than left to `grep -r`, and that is a bug
  # fix, not a style choice. In a built generation `home-files`, `home-path` and
  # `LaunchAgents` are symlinks into the store, and BSD grep does not follow a
  # symlink it meets while recursing - neither -r nor -R does, only -S, which is
  # not a GNU grep flag and so not portable enough to rely on here. So
  # `grep -r "$generation"` read only `activate`, `bin/` and three small text
  # files, and reported ok for a scope it had never opened. home-files is
  # exactly where a regression would land: a future `home.file` whose text
  # embeds a Cellar path or a `brew shellenv` line lands there.
  #
  # home-path is deliberately NOT in scope. It is the nixpkgs package closure,
  # not this repository's output. A Homebrew path inside some upstream package
  # is a fact about that package and not evidence that this configuration
  # reaches into Homebrew, so scanning it would produce hits nobody here can act
  # on - the fastest way to teach someone to ignore this check.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  script=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"

  # What stops the scope from narrowing again in silence. The generated Brewfile
  # lives under home-files and this suite knows it is there, so a traversal that
  # cannot reach it is not reading what this check claims to read - and a check
  # that can go quiet is the failure being fixed here, not a smaller version of
  # it.
  find -L "$generation/activate" "$generation/home-files" "$script" -type f -print 2>/dev/null \
    | grep -q -F "/home-files/.config/dotfiles/Brewfile" \
    || fail "the artifact scan never reached the generated Brewfile, so it is reading less than it claims"

  hits=$(find -L "$generation/activate" "$generation/home-files" "$script" -type f -print0 2>/dev/null \
    | xargs -0 grep -o -h -E '/opt/homebrew[A-Za-z0-9_./-]*|/usr/local/(Homebrew|Cellar|Caskroom)[A-Za-z0-9_./-]*|/usr/local/bin/brew' \
    2>/dev/null | sort -u || true)

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "$hit" in
      /opt/homebrew/bin/brew|/usr/local/bin/brew) : ;;
      *) unexpected="$unexpected $hit" ;;
    esac
  done <<EOF
$hits
EOF

  [ -z "$unexpected" ] \
    || fail "the activation package reaches into Homebrew's own tree, not just its brew:$unexpected"

  # Both of them, and not merely "nothing unexpected". An empty result would
  # pass the check above while meaning the artifact had stopped looking for
  # Homebrew at all - which is how a check that guards a narrowing quietly
  # becomes a check that guards nothing.
  assert_contains "$hits" "/opt/homebrew/bin/brew" \
    "the activation package does not look for Homebrew on Apple silicon"
  assert_contains "$hits" "/usr/local/bin/brew" \
    "the activation package does not look for Homebrew on Intel"

  pass "artifact: the only Homebrew paths are the two prefixes an existing \`brew\` lives at"
}

test_flake_pulls_in_no_system_configuration_tool
test_configuration_has_no_system_level_options
test_every_managed_file_target_is_inside_home
test_home_directory_matches_the_declared_one
test_no_tracked_script_escalates_privileges
test_nothing_here_installs_homebrew
test_the_homebrew_scan_tells_an_invocation_from_a_path_test
test_the_only_homebrew_paths_are_the_two_prefixes

test_summary
