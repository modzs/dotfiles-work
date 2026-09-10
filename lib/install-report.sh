#!/usr/bin/env bash
# lib/install-report.sh - what bootstrap.sh says once the switch has succeeded.
#
# Sourced by bootstrap.sh. It lives here rather than inline so that
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
# build output. That is true and it is not enough. A user arriving from a
# personal dotfiles repo, where a system package manager drops apps into
# /Applications, looks in /Applications, looks at `brew list`, types a tool
# name in the shell they just ran this from, finds nothing in any of the three,
# and concludes the run did nothing. All three are expected states here, and
# none of them was said out loud at the moment it mattered.
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
# - `env -i` and an explicit system PATH. bootstrap.sh reaches this point with
#   nix on its OWN PATH, because step 1 sourced the Determinate profile script
#   into this process. Inheriting that would make the probe agree that all is
#   well about the exact thing it exists to doubt.
# - `zsh -f`, then sourcing the startup files explicitly. This runs the system
#   files and the two user files that legitimately set PATH; it deliberately
#   does not source ~/.zshrc, which is interactive-only, is this configuration's
#   own file, and sets no PATH. Anything missed that way is a false warning,
#   never a false all-clear.
install_report_login_path() {
  local probe result
  command -v zsh >/dev/null 2>&1 || return 1

  # shellcheck disable=SC2016  # every expansion in here is zsh's to make, not this shell's
  probe='
for f in /etc/zshenv "$HOME/.zshenv" /etc/zprofile "$HOME/.zprofile" /etc/zshrc; do
  [ -r "$f" ] && . "$f"
done
print -rn -- "$PATH"
'
  result=$(env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TERM=dumb \
    zsh -f -c "$probe" </dev/null 2>/dev/null) || return 1
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

# --- the report ---------------------------------------------------------------

# $1 is an optional indent so bootstrap.sh's step margin is preserved.
install_report() {
  local indent=${1:-}
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
    printf '%sWARNING: ~/.nix-profile/bin is empty or missing, so this account\n' "$indent"
    printf '%shas no command-line tools from this configuration - even though\n' "$indent"
    printf '%sthe switch above reported success. Something is wrong; this run\n' "$indent"
    printf '%sis not finished.\n' "$indent"
    printf '\n'
    printf '%sLook at what is really there, then run ./bootstrap.sh again:\n' "$indent"
    printf '%s  ls -la ~/.nix-profile/bin\n' "$indent"
    printf '\n'
    printf '%sThe Troubleshooting section of HOW-TO.md covers what comes up.\n' "$indent"
    return 0
  fi

  printf '%s~/.nix-profile/bin now holds %s command-line tools, and WezTerm and\n' "$indent" "$count"
  printf '%sGhostty are in ~/Applications/Home Manager Apps.\n' "$indent"
  printf '\n'

  # First, because everything else here is unverifiable from the shell the user
  # is standing in. This is the sentence whose absence turned a complete
  # install into "it installed nothing".
  printf '%sNone of it is on THIS terminal PATH. Nix only adds itself to\n' "$indent"
  printf '%sshells that start after it was installed, so this shell - the one\n' "$indent"
  printf '%syou ran ./bootstrap.sh from - cannot see any of it, and neither can\n' "$indent"
  printf '%s./rebuild.sh if you run it here.\n' "$indent"
  printf '\n'
  printf '%s  ==> Open a new terminal now. Everything below assumes you have.\n' "$indent"

  install_report_reachability_note "$indent"

  printf '\n'
  printf '%sCheck what you got:\n' "$indent"
  printf '%s  ls ~/.nix-profile/bin\n' "$indent"
  printf '%s  ls ~/Applications/Home\\ Manager\\ Apps\n' "$indent"
  printf '\n'
  printf '%sTwo things that surprise people:\n' "$indent"
  printf '%s  - The terminal apps are symlinks in ~/Applications/Home Manager\n' "$indent"
  printf '%s    Apps, not copies in /Applications, and Spotlight will not index\n' "$indent"
  printf '%s    them. Start one by path, or just type wezterm or ghostty.\n' "$indent"
  printf '%s  - This installs no Homebrew and never will, so "brew list" stays\n' "$indent"
  printf '%s    empty. Everything above came from nixpkgs instead. README.md\n' "$indent"
  printf '%s    explains why a machine you do not administer gets neither a\n' "$indent"
  printf '%s    system package manager nor anything in /Applications.\n' "$indent"

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
