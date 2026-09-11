#!/usr/bin/env bash
# The design rule, made executable.
#
# The rule this repository exists for is that it must not reconfigure a Mac the
# user does not administer. It used to be stated as "nothing it does may affect
# anything outside the user's home directory", and every check here enforced
# that literally.
#
# That is no longer the whole truth, and this file says so out loud rather than
# quietly enforcing less. The rule has narrowed twice now, both times on the
# owner's instruction, and the checks below have narrowed with it - each time by
# splitting one absolute assertion into the narrower ones that are still true,
# never by deleting it.
#
# First, this configuration started driving Homebrew: it generates a Brewfile
# and asks Homebrew to install what it lists, which writes into the Homebrew
# prefix and puts casks in /Applications.
#
# Then it started installing Homebrew. Homebrew's source is a pinned flake
# input, home.nix patches the store copy and generates a `brew` around it,
# bootstrap.sh creates the standard prefix behind one announced `sudo`, and the
# switch links the two together. So:
#
# - test_flake_pulls_in_no_system_configuration_tool now permits exactly one
#   more input, by identity rather than by name: `brew-src` has to resolve to
#   Homebrew/brew and be a non-flake source. nix-darwin, darwin and nix-homebrew
#   stay banned outright, which is the assertion that matters - the whole design
#   is a port of nix-homebrew's technique WITHOUT nix-homebrew's module;
# - test_no_tracked_script_escalates_privileges now permits exactly one `sudo`,
#   in bootstrap.sh, invoking exactly one script. Everything else, everywhere
#   else, still fails - and test_the_privilege_scan_still_catches_an_escalation
#   runs the scanner against fixtures so the narrowing cannot quietly become a
#   hole;
# - test_nothing_here_installs_homebrew keeps its full strength. Getting
#   Homebrew from a pinned flake input is the entire point, so a script that
#   fetched or cloned or installed it at run time is exactly as wrong as it ever
#   was;
# - test_the_only_homebrew_paths_are_the_two_prefixes has grown from two paths
#   to six, and now asserts the exact set rather than a rule of thumb about how
#   many there should be.
#
# Nothing else changed. Every other check below is the original one: no
# nix-darwin, no system-level options, no managed file outside $HOME. In
# particular the system-level option check is untouched and must stay passing:
# if it ever fails, a nix-darwin module has been mixed in and the design is
# wrong.
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
dotfiles_test_expect 9

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
  #
  # The banned list keeps the three names that matter and has dropped the two it
  # can no longer carry. `brew` and `homebrew` were on it because this repo used
  # to have no business fetching Homebrew at all; it now installs Homebrew from
  # a pinned source, so an input matching those names is the design working. The
  # replacement is not a looser name check but a stricter identity one: there is
  # exactly one such input, it is named brew-src, it must resolve to
  # Homebrew/brew, and it must be `flake = false` - a plain source tree, not a
  # flake whose own inputs could pull anything else in behind it.
  #
  # nix-darwin, darwin and nix-homebrew stay banned, and that is the load-bearing
  # half. nix-homebrew's technique is ported into home.nix by hand precisely
  # because its only output is a nix-darwin module, and importing it would drag
  # in the tool this repository exists not to use.
  report=$(python3 - "$ROOT/flake.lock" <<'PY'
import json, sys

BANNED = ("nix-darwin", "darwin", "nix-homebrew")
EXPECTED_ROOT_INPUTS = {"home-manager", "nixpkgs", "brew-src"}

# The one input allowed to be about Homebrew, and exactly what it has to be.
BREW_INPUT = "brew-src"
BREW_OWNER = "homebrew"
BREW_REPO = "brew"

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
    if name == BREW_INPUT:
        # Checked by what it IS, not by what it is called. A node named
        # brew-src that resolved somewhere else would be the whole guard
        # defeated by a rename.
        if locked.get("owner", "").lower() != BREW_OWNER \
                or locked.get("repo", "").lower() != BREW_REPO:
            problems.append(
                "input %r resolves to %r, not to Homebrew/brew"
                % (name, " ".join(f for f in fields if f))
            )
        if node.get("flake") is not False:
            problems.append(
                "input %r is a flake; it must be `flake = false` so that nothing"
                " can arrive through its own inputs" % (name,)
            )
        continue

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

  pass "flake: the locked inputs are nixpkgs, home-manager and Homebrew's own source, and nothing else"
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

# Write the privilege-escalation scanner to a temp file and print its path.
# Split out from its caller so the checker itself can be run against fixture
# scripts whose answer is known - the same reason the Homebrew scanner below is
# split out, and a more pressing one now that this check has an exception in it.
dotfiles_write_privscan() {
  local script
  script=$(mktemp "${TMPDIR:-/tmp}/dotfiles-tokenize.XXXXXX") \
    || fail "could not create a temp file for the tokenizer"
  cat >"$script" <<'SCAN'
import os, shlex, sys

# Every macOS way of running something as another user, plus the AppleScript
# spelling that raises an authorization dialog.
BANNED = {"sudo", "doas", "su", "sudoedit", "pkexec"}
APPLESCRIPT = "with administrator privileges"

# THE ONE EXCEPTION, and it is written as narrowly as it can be written.
#
# This configuration installs Homebrew, which means creating a prefix outside
# the home directory and giving it to the user. That needs root exactly once,
# and it happens in bootstrap.sh. Everything after it - every rebuild, every
# `brew install` the Brewfile asks for - runs as the user in a prefix the user
# now owns, which is what lets rebuild.sh still promise it never asks for a
# password.
#
# So the exception is not "bootstrap.sh may use sudo". It is: bootstrap.sh may
# contain exactly ONE privilege token, it must be `sudo`, and the word after it
# must be this one script. A second sudo, a sudo running anything else, a sudo
# with an option in front of the path, or the same call in any other file, all
# still fail. test_the_privilege_scan_still_catches_an_escalation runs this
# against fixtures for every one of those.
ALLOWED_FILE = "bootstrap.sh"
ALLOWED_TOKEN = "sudo"
ALLOWED_TARGET = "$DIR/lib/homebrew-initialize-prefix.sh"

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

    exception_available = os.path.basename(path) == ALLOWED_FILE
    for index, token in enumerate(tokens):
        if token not in BANNED:
            continue
        following = tokens[index + 1] if index + 1 < len(tokens) else ""
        if (exception_available
                and token == ALLOWED_TOKEN
                and following == ALLOWED_TARGET):
            # Used up. A second one in the same file is a problem again, which
            # is how "exactly one" is enforced rather than "at least one".
            exception_available = False
            continue
        problems.append("%s: runs %r" % (path, token))

    if APPLESCRIPT in source.lower():
        problems.append("%s: contains %r" % (path, APPLESCRIPT))

print("\n".join(problems))
SCAN

  printf '%s\n' "$script"
}

test_no_tracked_script_escalates_privileges() {
  local script report status=0
  if ! command -v python3 >/dev/null 2>&1; then
    skip "privilege escalation check (python3 not found)"
    return 0
  fi

  # A real shell tokenizer, so a word inside a comment is not mistaken for a
  # command and a command is not missed because of the spacing around it. The
  # rebuild path must never prompt for a password: the whole promise of this
  # repo is that it is usable on a machine the user does not administer, and
  # the one exception the scanner carries is confined to bootstrap.sh.
  #
  # The tokenizer goes into a temp file rather than onto python's stdin,
  # because stdin is already spoken for - it is where xargs reads the file list.
  script=$(dotfiles_write_privscan) \
    || fail "could not write the privilege-escalation scanner"

  # This file excludes itself: it has to spell out the words it forbids in
  # order to look for them.
  report=$(dotfiles_tracked_except "$(dotfiles_test_self)" '*.sh' \
    | xargs -0 python3 "$script") || status=$?
  rm -f "$script"
  [ "$status" = 0 ] || fail "could not tokenize the tracked shell scripts"

  [ -z "$report" ] \
    || fail "a tracked script escalates privileges: $report"

  pass "scripts: the only privilege escalation is bootstrap.sh's single announced sudo"
}

test_the_privilege_scan_still_catches_an_escalation() {
  local script root case_name body verdict report status=0

  if ! command -v python3 >/dev/null 2>&1; then
    skip "privilege scanner behaviour check (python3 not found)"
    return 0
  fi

  # The check above passes by finding nothing, which is also what a scanner
  # that cannot see anything does - and it now carries an exception, which is
  # exactly the shape of thing that quietly widens. So it is run here against a
  # matrix of one-line scripts whose verdict is known in advance.
  #
  # The file NAME decides whether the exception is even available, so each
  # fixture is written under the name it has to be judged as. The rows that
  # matter most are the near misses: the same sudo in another file, a second one
  # in bootstrap.sh, and a sudo whose next word is anything else.
  script=$(dotfiles_write_privscan) \
    || fail "could not write the privilege-escalation scanner"
  root=$(dotfiles_test_tmproot dotfiles-privscan-fixtures)

  # <verdict> <filename> <shell line>. The line is the remainder of the record.
  while read -r verdict case_name body; do
    [ -n "$case_name" ] || continue
    mkdir -p "$root/$case_name"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$root/$case_name/$case_name.sh"

    report=$(python3 "$script" "$root/$case_name/$case_name.sh") || status=$?
    [ "$status" = 0 ] || fail "the scanner could not tokenize the $case_name fixture"

    case $verdict in
      flag)
        [ -n "$report" ] \
          || fail "the privilege scanner passed \"$body\" in $case_name.sh, which escalates" ;;
      pass)
        [ -z "$report" ] \
          || fail "the privilege scanner flagged \"$body\" in $case_name.sh: $report" ;;
      *) fail "the $case_name fixture declares an unknown verdict: $verdict" ;;
    esac
  done <<'MATRIX'
flag rebuild sudo "$DIR/lib/homebrew-initialize-prefix.sh" a b c d
flag someotherfile sudo "$DIR/lib/homebrew-initialize-prefix.sh" a b c d
flag plainsudo sudo chown -R me /opt/homebrew
flag doas doas chown -R me /opt/homebrew
flag applescript osascript -e 'do shell script "x" with administrator privileges'
flag sudoflag sudo -n "$DIR/lib/homebrew-initialize-prefix.sh" a b c d
flag sudoother sudo "$DIR/lib/something-else.sh" a b c d
pass bootstrap sudo "$DIR/lib/homebrew-initialize-prefix.sh" a b c d
pass comment # explaining that sudo is what the Nix installer needs
MATRIX

  # "Exactly one", which a single-line fixture cannot express: the second call
  # in the same bootstrap.sh has to be flagged even though the first is allowed.
  mkdir -p "$root/twice"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # $DIR is fixture text, not an expansion
    printf 'sudo "$DIR/lib/homebrew-initialize-prefix.sh" a b c d\n'
    # shellcheck disable=SC2016  # as above
    printf 'sudo "$DIR/lib/homebrew-initialize-prefix.sh" e f g h\n'
  } >"$root/twice/bootstrap.sh"
  report=$(python3 "$script" "$root/twice/bootstrap.sh") || status=$?
  [ "$status" = 0 ] || fail "the scanner could not tokenize the twice fixture"
  [ -n "$report" ] \
    || fail "the privilege scanner allowed a SECOND sudo in bootstrap.sh, so the exception is not 'exactly one'"

  rm -f "$script"

  pass "scripts: the privilege scan flags every escalation and allows only bootstrap.sh's one call"
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
import re, shlex, sys

# The contract is that no script this repo runs may INVOKE Homebrew. Naming its
# path is a different act and a legitimate one: lib/homebrew-present.sh has to
# ask whether /opt/homebrew/bin/brew exists, because bootstrap.sh must turn a
# Mac without Homebrew away before it installs Nix. A check that cannot tell
# `[ -x /opt/homebrew/bin/brew ]` from running brew was asserting the wrong
# thing, so this one looks at POSITION.
#
# It asks that question in the direction that FAILS CLOSED: a token whose
# basename is `brew` counts as an invocation unless something makes it
# unmistakably an argument. The previous shape asked the opposite - it listed
# the tokens after which `brew` counted as a command - and every construct
# nobody had thought to list was silently permitted. `if brew ...`,
# `while brew ...`, `until brew ...`, `exec brew ...` and `command brew ...`
# all passed a check whose whole purpose is to forbid them, because `if`,
# `while` and `until` were missing from a list that had `then` and `do`. That
# list could never be finished: a command prefix is any word, so the ways of
# reaching `brew` are open ended, while the ways of making it an argument are
# few and belong to this repository. Getting this direction wrong costs a
# comment on the list below; getting the old one wrong cost the guarantee.
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

# The complete set of things that make a `brew` token an argument rather than a
# command. Each entry is here because this repository needs it, and anything
# not on it is treated as an invocation.
ARGUMENT_INTRODUCERS = {
    # A path existence test, which is the one use this repo actually has:
    # `[ -x /opt/homebrew/bin/brew ]`. The full set of unary file operators,
    # so a future check can use whichever one fits.
    "-b", "-c", "-d", "-e", "-f", "-g", "-h", "-k", "-L", "-p",
    "-r", "-S", "-s", "-u", "-w", "-x", "-O", "-G", "-N",
    # `for candidate in <paths>` and `case x in` introduce a word list, never
    # a command.
    "in",
}

# A command substitution reaches `brew` however it is spelled, so a token
# carrying one is an invocation whatever precedes it.
SUBSTITUTION_OPENERS = ("`", "$(")

# NAME=value. An assignment names a path, it does not run it. Combined with the
# substitution check above, `x=/opt/homebrew/bin/brew` is allowed while
# x=`brew --prefix` is not.
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

INSTALLERS = (
    "raw.githubusercontent.com/homebrew",
    "homebrew/install",
    "github.com/homebrew/brew",
)

NEWLINE = "\x00NL\x00"


# The name a token would run, with any command-substitution opener stripped so
# that x=`brew --prefix` is seen as `brew` rather than as "x=`brew".
def command_name(token):
    text = token
    for opener in SUBSTITUTION_OPENERS:
        found = text.rfind(opener)
        if found != -1:
            text = text[found + len(opener):]
    return text.rsplit("/", 1)[-1]


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
        if command_name(token) in BANNED:
            argument = (
                ASSIGNMENT.match(token) is not None
                or previous in ARGUMENT_INTRODUCERS
                # The second and later paths in a word list, whose predecessor
                # is the path before them.
                or command_name(previous) in BANNED
            )
            if any(opener in token for opener in SUBSTITUTION_OPENERS) or not argument:
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
  # What this cannot catch, stated plainly because a guard someone believes is
  # total is worse than one whose edge is written down: it matches a literal
  # command word, so a script that put a brew path in a variable and ran
  # `"$BREW" install ...` would tokenize as `$BREW`, whose basename is not
  # `brew`, and pass. Nothing here does that - lib/homebrew-present.sh reports
  # the path it finds rather than returning one, so no script holds a runnable
  # `brew` - but that is a property of how these scripts are written, not
  # something this check enforces.
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
  local script root case_name body verdict report status=0

  if ! command -v python3 >/dev/null 2>&1; then
    skip "Homebrew scanner behaviour check (python3 not found)"
    return 0
  fi

  # The check above passes by finding nothing, which is also what a scanner
  # that cannot see anything does. So the scanner is run here against a matrix
  # of one-line scripts whose verdict is known in advance.
  #
  # A matrix and not two examples, because this check has now been narrower
  # than it claimed twice, and both times the reason was the same: its test
  # exercised only the spelling someone had thought of. The first time, every
  # file tokenized to nothing and it passed everything. The second time it read
  # `brew install` at the start of a line but not `if brew ...`, `while
  # brew ...`, `exec brew ...` or `command brew ...`. Every row below is a
  # spelling that was once wrong or is a case the rule deliberately permits, so
  # a third narrowing has to break a named row rather than slip through a gap.
  #
  # `subshell` and `arraysubst` are the two rows that pin the direction: a
  # parenthesised group and a command substitution are both places a `brew` can
  # hide, and both must stay flagged.
  script=$(dotfiles_write_brewscan) \
    || fail "could not write the Homebrew-invocation scanner"
  root=$(dotfiles_test_tmproot dotfiles-brewscan-fixtures)

  # <verdict> <name> <shell line>. The line is the remainder of the record, so a
  # fixture is free to contain the pipe, semicolon and quote characters that
  # shell invocations are actually written with.
  while read -r verdict case_name body; do
    [ -n "$case_name" ] || continue
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$root/$case_name.sh"

    report=$(python3 "$script" "$root/$case_name.sh") || status=$?
    [ "$status" = 0 ] || fail "the scanner could not tokenize the $case_name fixture"

    case $verdict in
      flag)
        [ -n "$report" ] \
          || fail "the scanner passed \"$body\", which invokes Homebrew - the check would not catch it in a real script" ;;
      pass)
        [ -z "$report" ] \
          || fail "the scanner flagged \"$body\", which only names a path: $report" ;;
      *) fail "the $case_name fixture declares an unknown verdict: $verdict" ;;
    esac
  done <<'MATRIX'
flag plain brew install nix
flag abspath /opt/homebrew/bin/brew bundle install
flag negated if ! /opt/homebrew/bin/brew --version >/dev/null 2>&1; then :; fi
flag if if brew list --formula >/dev/null; then :; fi
flag while while brew outdated; do :; done
flag until until brew list; do :; done
flag exec exec /opt/homebrew/bin/brew bundle install
flag commandprefix command brew install nix
flag casearm case x in y) brew install z ;; esac
flag pipeline true | brew install nix
flag substitution prefix=$(brew --prefix)
flag backtick prefix=`brew --prefix`
flag subshell ( brew install nix )
flag arraysubst dirs=( $(brew --prefix) )
pass pathtest [ -x /opt/homebrew/bin/brew ] && echo found
pass wordlist for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$c" ]; done
pass quotedlist searched="/opt/homebrew/bin/brew /usr/local/bin/brew"
MATRIX

  rm -f "$script"

  pass "scripts: the Homebrew scan flags every spelling of an invocation and allows a path test"
}

# --- the Homebrew paths the artifact embeds are exactly the ones it needs -----

test_the_only_homebrew_paths_are_the_two_prefixes() {
  local generation bundle setup extra hit hits missing unexpected=""
  local prefix library allowed
  if ! command -v nix >/dev/null 2>&1; then
    skip "Homebrew path check (nix not found)"
    return 0
  fi

  # This check began as "the built activation package contains no Homebrew path
  # at all". It then allowed two, the prefixes an existing `brew` could be
  # found at. It now allows six, because this configuration installs Homebrew:
  # it creates the prefix, synthesizes the library inside it, builds a fake
  # repository there and links a generated launcher into its bin. Each of those
  # is a path, and each has to be written down somewhere.
  #
  # So the shape of the assertion has changed with it, and this is the important
  # part: it is no longer "not more than N". It is the EXACT SET. A seventh path
  # is a failure, and so is a sixth that is not one of these - the difference
  # between a check that notices a new reach into Homebrew's tree and one that
  # merely counts.
  #
  # Both architectures produce the same set, and that is not a coincidence worth
  # hiding: lib/homebrew-present.sh carries the arm and the Intel answer in one
  # `case`, so whichever machine builds it, the library names both.
  #
  # This checks the built artifact, not the source: a path in a comment is not a
  # path the machine follows. Five things are in scope - the activate script,
  # the generated home-files tree, the Homebrew bundle step, the prefix-setup
  # step, and the two files that step names (the library it sources and the
  # `brew` it links). The last three are new, and leaving them out is exactly
  # how this check would have gone quiet: the setup step is where every new path
  # lives, and scanning only what was in scope before would have reported "ok"
  # for a scope that no longer contained the interesting file.
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
  # Two things are deliberately NOT in scope. home-path is the nixpkgs package
  # closure, not this repository's output: a Homebrew path inside some upstream
  # package is a fact about that package, and scanning it would produce hits
  # nobody here can act on - the fastest way to teach someone to ignore this
  # check. The patched Homebrew tree is out for the stronger version of the same
  # reason: it IS Homebrew, every path in it is Homebrew's own, and asserting
  # anything about them would be asserting something about upstream.
  generation=$(dotfiles_generation "$SYSTEM") \
    || fail "could not build the activation package"
  bundle=$(dotfiles_brew_bundle_script "$generation") \
    || fail "the activation script does not run a Homebrew step at all"
  setup=$(dotfiles_homebrew_prefix_script "$generation") \
    || fail "the activation script does not run a Homebrew prefix-setup step at all"
  extra=$(dotfiles_homebrew_prefix_script_files "$setup") \
    || fail "the prefix-setup step names neither a library to source nor a brew to link"

  # What stops the scope from narrowing again in silence. The generated Brewfile
  # lives under home-files and this suite knows it is there, so a traversal that
  # cannot reach it is not reading what this check claims to read - and a check
  # that can go quiet is the failure being fixed here, not a smaller version of
  # it.
  # shellcheck disable=SC2086  # the two extra paths are store paths, never spaced
  find -L "$generation/activate" "$generation/home-files" "$bundle" "$setup" $extra \
    -type f -print 2>/dev/null \
    | grep -q -F "/home-files/.config/dotfiles/Brewfile" \
    || fail "the artifact scan never reached the generated Brewfile, so it is reading less than it claims"

  # A trailing full stop or slash is stripped before the set is compared. Two of
  # the five files in scope are shell scripts with comments in them, and a
  # sentence that ends "...at /opt/homebrew." otherwise yields a path with the
  # sentence's punctuation stuck to it. No real path ends in either character,
  # so this cannot hide one.
  #
  # Prose paths do count, and that is the deliberate choice rather than an
  # oversight: keeping them in means a comment cannot mention a corner of
  # Homebrew's tree that the code has no business touching without someone
  # having to widen this list on purpose.
  # shellcheck disable=SC2086  # as above
  hits=$(find -L "$generation/activate" "$generation/home-files" "$bundle" "$setup" $extra \
    -type f -print0 2>/dev/null \
    | xargs -0 grep -o -h -E '/opt/homebrew[A-Za-z0-9_./-]*|/usr/local[A-Za-z0-9_./-]*' \
    2>/dev/null | sed -e 's#[./]*$##' | sort -u || true)

  # The complete set, and why each one is here:
  #
  #   /opt/homebrew                  the prefix on Apple silicon
  #   /opt/homebrew/Library          its library, which holds the code symlink
  #   /opt/homebrew/bin/brew         the launcher, and the first place the
  #                                  bundle step looks
  #   /usr/local                     the prefix on Intel
  #   /usr/local/Homebrew/Library    its library - one level down, because
  #                                  /usr/local belongs to the whole machine
  #   /usr/local/bin/brew            the Intel launcher, and the bundle step's
  #                                  second candidate
  #
  # Nothing names the marker file or the fake repository, and that is worth
  # knowing rather than being a gap: the library builds both from the prefix it
  # was given, so neither is a literal anywhere.
  allowed="/opt/homebrew
/opt/homebrew/Library
/opt/homebrew/bin/brew
/usr/local
/usr/local/Homebrew/Library
/usr/local/bin/brew"

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "
$allowed" in
      *"
$hit") : ;;
      *"
$hit
"*) : ;;
      *) unexpected="$unexpected $hit" ;;
    esac
  done <<EOF
$hits
EOF

  [ -z "$unexpected" ] \
    || fail "the activation package reaches into Homebrew's own tree, not just the paths it manages:$unexpected"

  # Every one of them, and not merely "nothing unexpected". An empty result
  # would pass the check above while meaning the artifact had stopped setting
  # Homebrew up at all - which is how a check that guards a narrowing quietly
  # becomes a check that guards nothing.
  missing=""
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "
$hits" in
      *"
$hit") : ;;
      *"
$hit
"*) : ;;
      *) missing="$missing $hit" ;;
    esac
  done <<EOF
$allowed
EOF

  [ -z "$missing" ] \
    || fail "the activation package no longer names these Homebrew paths, so part of the setup has stopped happening:$missing"

  # And the pair this architecture's own steps are built for, named explicitly
  # so that a build for the wrong prefix is a failure rather than a set that
  # happens to match because the shared library mentions both.
  prefix=/opt/homebrew
  library=/opt/homebrew/Library
  if [ "$SYSTEM" = x86_64-darwin ]; then
    prefix=/usr/local
    library=/usr/local/Homebrew/Library
  fi
  assert_contains "$(cat "$setup")" "\"$prefix\" \"$library\"" \
    "the prefix-setup step is not built for this architecture's Homebrew prefix"

  pass "artifact: the Homebrew paths are exactly the six this configuration manages"
}

test_flake_pulls_in_no_system_configuration_tool
test_configuration_has_no_system_level_options
test_every_managed_file_target_is_inside_home
test_home_directory_matches_the_declared_one
test_no_tracked_script_escalates_privileges
test_the_privilege_scan_still_catches_an_escalation
test_nothing_here_installs_homebrew
test_the_homebrew_scan_tells_an_invocation_from_a_path_test
test_the_only_homebrew_paths_are_the_two_prefixes

test_summary
