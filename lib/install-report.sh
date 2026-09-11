#!/usr/bin/env bash
# lib/install-report.sh - what a script says once its switch has succeeded.
#
# Sourced by bootstrap.sh, which ends on the full report, and by rebuild.sh,
# which ends on the shorter install_report_rebuild_verdict at the bottom of
# this file. It lives here rather than inline so that
# tests/install-report.test.sh can drive it against a scratch home, because
# this is the only thing a first-time user reads and it is easy to get wrong in
# a way no build failure would ever catch.
#
# The rule it exists to obey:
#
#   A successful run must say what it installed, where that went, and whether
#   the user's next terminal will actually be able to see it.
#
# The report this replaces was two lines - "Done." and "Open a new terminal,
# then use ./rebuild.sh for future changes" - printed after forty lines of Nix
# build output. That is true and it is not enough. A user types a tool name in
# the shell they just ran this from, finds nothing, and concludes the run did
# nothing: the Nix half of the install reaches only shells started afterwards,
# which is an expected state that nothing said out loud at the moment it
# mattered. What was installed is also split across two package managers now,
# so "where did it go" has two answers rather than one.
#
# Must stay bash 3.2 compatible - macOS ships no newer bash. See AGENTS.md.

# How many command-line tools this account's profile carries right now. Read
# off the profile rather than counted from home.nix: the number a user can
# check with `ls` is the only one worth printing, and one package can install
# more than one binary.
install_report_tool_count() {
  local bin="$HOME/.nix-profile/bin" entry count=0
  # A glob and a loop rather than `ls | wc -l`: the entries here are symlinks
  # into the store, and counting them is not worth a pipeline that has to be
  # right about how ls and find each treat a symlinked directory. An absent
  # profile leaves the pattern unmatched, which the -e test rejects, so the
  # answer is 0 rather than 1.
  for entry in "$bin"/*; do
    [ -e "$entry" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# --- will the next terminal see any of this? ----------------------------------
#
# Nothing this repository writes puts the installed tools on PATH. The profile
# is reached through a line the Nix installer appends to /etc/zshrc, a system
# file this repo must never touch and does not own - and on a machine somebody
# else administers, a re-deployed /etc/zshrc takes it away again. The result is
# a switch that succeeds completely and a user for whom every single command is
# "not found", with no error anywhere to explain it.
#
# So the report asks rather than assumes. It cannot fix this and does not try;
# it names the file to look at and says who is likely to have changed it.

# Print the PATH a fresh login shell would start with, or fail if that cannot
# be established.
#
# Two things make this honest rather than decorative:
#
# - `env -i` and an explicit system PATH. Both callers reach this point with
#   nix on their OWN PATH - bootstrap.sh because step 1 sourced the Determinate
#   profile script into this process, rebuild.sh because it refuses to run
#   without it at all. Inheriting that would make the probe agree that all is
#   well about the exact thing it exists to doubt.
# - `zsh -f`, then sourcing the startup files explicitly. This runs the system
#   files and the user files that legitimately set PATH; it deliberately does
#   not source ~/.zshrc, which is interactive-only, is this configuration's own
#   file, and sets no PATH. Anything missed that way is a false warning, never
#   a false all-clear.
#   ~/.zshrc.local is the exception, and it is sourced last. It is the one file
#   README gives the user for exactly this repair, it is reached through
#   ~/.zshrc at lib.mkOrder 1500 so it really does run after /etc/zshrc, and a
#   check that could not see it would go on telling a user who had already
#   fixed his PATH that his tools are unreachable and his employer is at fault.
# - A marker on the answer. These startup files belong to whoever administers
#   the Mac, and one that prints a banner would otherwise have its own output
#   read as the front of PATH - which is where the profile sits, because the
#   Determinate installer puts its block at the top of /etc/zshrc. Only the
#   marked line is the answer; an answer with no marked line is no answer.
install_report_login_path() {
  local probe result marker='__dotfiles_login_path__'
  command -v zsh >/dev/null 2>&1 || return 1

  # The escaped expansions are zsh's to make, not this shell's; the marker is
  # this shell's, so it is written once and spliced in here.
  probe="
for f in /etc/zshenv \"\$HOME/.zshenv\" /etc/zprofile \"\$HOME/.zprofile\" /etc/zshrc \"\$HOME/.zshrc.local\"; do
  [ -r \"\$f\" ] && . \"\$f\"
done
print -r -- \"$marker\$PATH\"
"
  result=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=dumb \
    zsh -f -c "$probe" </dev/null 2>/dev/null) || return 1
  result=$(printf '%s\n' "$result" | grep "^$marker" | tail -n1) || return 1
  result=${result#"$marker"}
  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# 0 - a new terminal will find the installed tools
# 1 - it will not
# 2 - this could not be established, which is NOT the same as 0
install_report_profile_reachability() {
  local path
  path=$(install_report_login_path) || return 2
  case ":$path:" in
    *:"$HOME/.nix-profile/bin":*) return 0 ;;
    *) return 1 ;;
  esac
}

install_report_reachability_note() {
  local indent=$1 state=0
  install_report_profile_reachability || state=$?

  if [ "$state" = 0 ]; then
    printf '\n'
    printf '%sChecked: a new login shell does find them.\n' "$indent"
    return 0
  fi

  printf '\n'
  if [ "$state" = 2 ]; then
    printf '%sNot checked: this could not work out what a new terminal will\n' "$indent"
    printf '%ssee, so treat the next paragraph as unverified rather than fine.\n' "$indent"
  else
    printf '%sWARNING: a new terminal will not find them either.\n' "$indent"
  fi
  printf '\n'
  printf '%sA new shell gets these tools from a line the Nix installer adds to\n' "$indent"
  printf '%s/etc/zshrc, and that line does not appear to be in effect on this\n' "$indent"
  printf '%sMac. On a machine somebody else administers, the usual reason is\n' "$indent"
  printf '%smanagement software re-deploying /etc/zshrc and dropping it.\n' "$indent"
  printf '\n'
  printf '%sThis repository will not edit /etc, so it cannot put the line back\n' "$indent"
  printf '%sfor you. Look at:\n' "$indent"
  printf '%s  grep -i nix /etc/zshrc\n' "$indent"
  printf '\n'
  printf '%sEverything listed above is installed either way. Until that line is\n' "$indent"
  printf '%sback, the tools still run by full path:\n' "$indent"
  printf '%s  ~/.nix-profile/bin/rg --version\n' "$indent"
}

# --- and the other half? ------------------------------------------------------
#
# Everything the report says about Homebrew, in one place. The counterpart to
# install_report_reachability_note, and deliberately not the same shape. That
# one PROBES: it starts a login shell and looks at the PATH it really gets.
# This one cannot, and must not pretend to. Nothing here reads Homebrew's
# environment, and the note at the bottom of install_report says why assuming
# in Homebrew's favour would be the one thing this file must not do.
#
# So it reports the one thing that is certain and needs no probe - that nothing
# in this repository writes a PATH line for Homebrew, exactly as nothing writes
# one for Nix - and then points at the same two places the Nix half points at:
# the command that fixes it, and the document that explains it.
#
# Written because the omission read as an answer. A report that probes one of
# the two package managers it just used and says nothing at all about the other
# leaves a user who cannot find `brew` with no thread to pull, while the user
# who cannot find `rg` gets a paragraph, a file to look at and a workaround.
#
# Every sentence here names its own subject. This paragraph used to open by
# pointing back at a neighbouring bullet, and each rewording of one end left
# the other end referring to something that was no longer there.
#
# $2 is the prefix, passed in rather than worked out. Which prefix this
# architecture uses is lib/homebrew-present.sh's question and has exactly one
# implementation; a second one here would be a second answer waiting to
# disagree. It is required, and that is what makes the property this whole file
# exists for hold here too: the report can only ever name a path something
# actually resolved, never one it guessed or stood in for.
install_report_homebrew_path_note() {
  local indent=$1 prefix=$2
  printf '\n'
  printf '%sHomebrew came from here too, pinned by flake.lock, and it cannot\n' "$indent"
  printf '%supdate itself. Nothing here ever asks it to remove anything, and\n' "$indent"
  printf '%sREADME.md is exact about what those steps do and do not do.\n' "$indent"
  printf '\n'
  printf '%sWhether a new terminal can find brew was not checked: this run\n' "$indent"
  printf '%sprobed ~/.nix-profile/bin and nothing else, and nothing here reads\n' "$indent"
  printf '%sthe environment Homebrew sets. Nothing here writes a PATH line for\n' "$indent"
  printf '%sHomebrew either, and the prefix was set up by a script, so nothing\n' "$indent"
  printf '%shas ever printed you one. If a new terminal cannot find the names\n' "$indent"
  printf '%son the Homebrew list, add to ~/.zprofile:\n' "$indent"
  printf '%s  eval "\044(%s/bin/brew shellenv)"\n' "$indent" "$prefix"
  printf '\n'
  printf '%sThe casks are unaffected - they are applications in /Applications.\n' "$indent"
  printf '%sHOW-TO.md says the same under Troubleshooting.\n' "$indent"
}

# The one state a successful switch can leave behind that produces no error
# anywhere: a profile with nothing in it. Both entry points can find it, so
# both say it the same way.
install_report_empty_profile_warning() {
  local indent=$1
  printf '%sWARNING: ~/.nix-profile/bin is empty or missing, so this account\n' "$indent"
  printf '%shas no command-line tools from this configuration - even though\n' "$indent"
  printf '%sthe switch above reported success. Something is wrong; this run\n' "$indent"
  printf '%sis not finished.\n' "$indent"
}

# --- the report ---------------------------------------------------------------

# $1 is an optional indent so bootstrap.sh's step margin is preserved. $2 is
# the Homebrew prefix the run resolved, for the note that points at it, and it
# is required: a report that named a prefix nothing had resolved would be the
# guess this file must not make.
install_report() {
  local indent=${1:-} prefix=$2
  local count
  count=$(install_report_tool_count)

  # What the profile HOLDS, not what this run put there. bootstrap.sh is safe
  # to run twice, and a second run that installs nothing new must not claim it
  # installed everything - that is the same overstatement this report exists to
  # remove. Nothing here can tell the two runs apart, so it does not try.
  #
  # Zero is not a small number here, it is a broken install: a switch that
  # reported success always leaves binaries in the profile. It must not read as
  # a cheerful "0 tools" either, and the reachability check below cannot catch
  # it - the /etc/zshrc line puts ~/.nix-profile/bin on PATH whether or not the
  # directory exists, so it would go on to confirm a new terminal finds tools
  # that are not there.
  if [ "$count" = 0 ]; then
    printf '==> Not done: nothing is installed.\n'
    install_report_empty_profile_warning "$indent"
    printf '\n'
    printf '%sThis shell cannot see nix - Nix only adds itself to shells that\n' "$indent"
    printf '%sstart after it was installed - so the retry has to happen in a\n' "$indent"
    printf '%snew one.\n' "$indent"
    printf '\n'
    printf '%s  ==> Open a new terminal, then run ./rebuild.sh from there.\n' "$indent"
    printf '\n'
    printf '%sWhat is really in the profile, from that new terminal:\n' "$indent"
    printf '%s  ls -la ~/.nix-profile/bin\n' "$indent"
    # An exit status is a claim too, and bootstrap.sh's is this function's:
    # `install_report` is its last statement. Only this branch fails the run,
    # because only here has the report established that nothing is installed.
    # A reachability check that could not answer, and an install that is
    # merely unreachable, both leave the status alone - the tools are there.
    return 1
  fi

  printf '==> Done.\n'
  printf '%s~/.nix-profile/bin now holds %s command-line tools, and the names on\n' "$indent" "$count"
  printf '%sthe Homebrew list in home.nix went where Homebrew puts them: its own\n' "$indent"
  printf '%sprefix, and /Applications for the casks that are applications.\n' "$indent"
  printf '\n'

  # First, because everything else here is unverifiable from the shell the user
  # is standing in. This is the sentence whose absence turned a complete
  # install into "it installed nothing".
  #
  # What this file may say, and the line not to cross. It reports what was
  # installed and where it went. It reports reachability only for the thing it
  # actually probes, which is ~/.nix-profile/bin and nothing else. It never
  # tells the user something is on their PATH without having checked.
  #
  # The Homebrew half is outside that: nothing here probes it, and it is not
  # safely assumable either. It is LESS assumable than it used to be, not more.
  # A hand-installed Homebrew at least prints the `brew shellenv` lines for the
  # user to paste; the prefix this configuration creates is set up by a script,
  # so nothing has ever told the user that line exists. Nothing here writes it
  # for them either - a login shell's PATH is not this repository's to edit -
  # which is why HOW-TO.md carries a troubleshooting entry for exactly that. A
  # friendly "and Homebrew's are already reachable" here would be the one thing
  # this file must not do.
  printf '%sNone of the Nix tools above is on THIS terminal PATH. Nix only adds\n' "$indent"
  printf '%sitself to shells that start after it was installed, so this shell -\n' "$indent"
  printf '%sthe one you ran ./bootstrap.sh from - cannot see any of them, and\n' "$indent"
  printf '%sneither can ./rebuild.sh if you run it here.\n' "$indent"
  printf '\n'
  printf '%s  ==> Open a new terminal now. Everything below assumes you have.\n' "$indent"

  install_report_reachability_note "$indent"

  printf '\n'
  printf '%sCheck what you got:\n' "$indent"
  printf '%s  ls ~/.nix-profile/bin\n' "$indent"
  printf '%s  brew list\n' "$indent"
  printf '\n'
  printf '%sWhat surprises people: what was installed came from two places,\n' "$indent"
  printf '%snot one. The tools above are from nixpkgs and live in your home\n' "$indent"
  printf '%sdirectory; the names on the Homebrew list went into the Homebrew\n' "$indent"
  printf '%sprefix, and the application casks to /Applications, where\n' "$indent"
  printf '%sSpotlight finds them like any other app.\n' "$indent"

  install_report_homebrew_path_note "$indent" "$prefix"

  install_report_zshrc_backup "$indent"

  printf '\n'
  printf '%sFrom a new terminal, ./rebuild.sh applies every later change.\n' "$indent"
}

# Say where the old file went, and only when it really was moved. The first
# switch passes -b backup, so a macOS account that already had a ~/.zshrc -
# almost all of them - now has it under another name, and nothing else in the
# run mentions that its contents did not simply vanish.
install_report_zshrc_backup() {
  local indent=$1
  [ -e "$HOME/.zshrc.backup" ] || return 0
  printf '\n'
  printf '%sYour previous ~/.zshrc was moved to ~/.zshrc.backup. Anything you\n' "$indent"
  printf '%swant to keep from it belongs in ~/.zshrc.local, which is sourced\n' "$indent"
  printf '%slast and is never committed.\n' "$indent"
}

# --- what rebuild.sh says when its switch succeeded ---------------------------
#
# Not the full report: a rebuild runs often, and a wall of text every time is
# how people learn to stop reading it. But the two questions that report exists
# to answer are exactly the two a successful rebuild can still leave wrong with
# no error anywhere - is anything actually installed, and can a new login shell
# reach it - and the report itself sends a user here to find out. So the
# verdict is one line when there is nothing to say, and the same warning
# bootstrap.sh gives when there is.
install_report_rebuild_verdict() {
  local count
  count=$(install_report_tool_count)

  printf '\n'
  if [ "$count" = 0 ]; then
    install_report_empty_profile_warning ''
    printf '\n'
    printf 'What is really there:\n'
    printf '  ls -la ~/.nix-profile/bin\n'
    # The same claim install_report makes, for the same reason and within the
    # same bounds: only a profile proven empty is a failed run. A probe that
    # could not answer, and an install that is merely out of reach, both leave
    # the status alone.
    return 1
  fi

  # shellcheck disable=SC2088  # the text the user reads, not a path to expand
  printf '~/.nix-profile/bin holds %s command-line tools.\n' "$count"
  install_report_reachability_note ''
}
