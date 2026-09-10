# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## The design rule

**This repository must not reconfigure a Mac the user does not administer.**

That is the entire reason it exists, separately from a personal dotfiles repo. It
is for Macs the user does not administer, where a configuration that renames the
machine or prunes system packages is not merely rude but dangerous - the setup
this one replaces would have uninstalled an employer's security agent.

The rule used to be stated more strictly, as "nothing this repository does may
affect anything outside the user's home directory", and for a while that was
literally true. It is not any more. On the owner's explicit instruction this
configuration now drives Homebrew: `home.nix` generates a Brewfile and a Home
Manager activation step runs `brew bundle install` against it on every switch,
which writes into Homebrew's prefix and puts casks in `/Applications`. That is
the one place the boundary has moved, it moved deliberately, and the honest
statement of what is left is the heading above.

What follows from it, and still holds without exception - this repo must never:

- rename the machine, or set any `networking.*` or `system.defaults` option;
- write to `/etc`, `/Library`, `/usr`, or `/opt`, other than by asking an
  existing Homebrew to install what the Brewfile lists;
- **install, update or remove Homebrew itself**, or any other system-wide
  package manager. Homebrew is the user's, installed by hand; this repo finds it
  and fails with an explanation when it is absent;
- **remove anything Homebrew installed.** There is no `cleanup`, no `--zap`, no
  `brew uninstall`, and there must never be one. On this machine Homebrew is the
  user's general-purpose package manager, so a declarative cleanup would delete
  software installed by hand for reasons this repo knows nothing about - a
  security agent among them. This is the single most dangerous change anyone
  could make here;
- manage other user accounts, sudoers, sshd, or PAM;
- require `sudo` for a rebuild. Installing Nix is the one and only `sudo`, and
  `bootstrap.sh` is the only place it happens - and it happens inside the
  Determinate installer, not in this repo's own code. Installing Homebrew needs
  a password too, which is exactly why this repo does not do it.

The rule is enforced mechanically, not by memory. `tests/safety.test.sh` fails if
the flake grows a nix-darwin input, if a system-level option namespace appears in
the evaluated configuration, if a managed file targets a path outside `$HOME`, if
any tracked script gains a privilege escalation, if any script this repo runs so
much as mentions Homebrew, or if the built artifact embeds a Homebrew path other
than the two an existing `brew` lives at. `tests/homebrew.test.sh` runs the
Homebrew step against a recording stand-in for `brew` and fails if it passes
anything that could uninstall, if a missing Homebrew produces a raw error rather
than an explanation, or if a tool ends up installed by both Nix and Homebrew.
Read both files before changing the structure of the configuration; they explain
what each check asserts and why a grep would not do.

The second rule, which follows from the first: **no employer-specific content,
ever**. No company names, domains, hostnames, proxy addresses, certificate paths
or internal registry URLs - not in code, not in comments, not in examples. This
repo is public. Anything of that shape belongs in the untracked local files
(`~/.zshrc.local`, `~/.gitconfig.local`, `~/.gitconfig.work`); README.md
documents that seam.

## Working here

- **A script refuses before it writes, and ends on the truth.** `rebuild.sh`
  checks everything that can refuse - the account and home directory, `nix` on
  PATH, `~/.dotfiles` - before anything is repointed or built. `bootstrap.sh`
  runs in a different order on purpose: it repoints `~/.dotfiles` at step 2 and
  only checks the account and home directory afterwards, with the nix-on-PATH
  guard later still, because the interactive personalize steps in between are
  what make that check pass. Neither may end a failed run on friendly advice.
  `rebuild.sh` once printed
  seven reassuring lines about git identity underneath `nix: command not
  found`, so a run that installed nothing read like a run that worked, and it
  repointed `~/.dotfiles` at a configuration it then refused.
  `tests/rebuild.test.sh` runs the script end to end against a scratch `HOME`
  with the switch stubbed, and holds both properties.
- **A successful run has to be legible.** `lib/install-report.sh` is what
  `bootstrap.sh` says at the end and, through
  `install_report_rebuild_verdict`, what `rebuild.sh` says after a successful
  switch - two callers share it. `tests/install-report.test.sh` drives it
  directly. Nothing this repo writes puts the profile on `PATH` - a line the
  Nix installer adds to `/etc/zshrc` does - so the report probes what a fresh
  login shell would really see and warns when it would see nothing. It names
  that file and never writes to it; a check that cannot answer must read as
  unverified, never as fine.
- **Never activate a configuration while testing.** `nix flake check`,
  `nix build .#default` and `nix eval` are safe; `home-manager switch`,
  `./rebuild.sh` and `./bootstrap.sh` rewrite a real home directory. Building an
  activation package is not activating it.
- Run the suite with `./tests/run.sh` (`--strict` in CI, where a skipped check is
  a failure). It works from any directory, and there is a test count behind that
  claim: every test file declares `dotfiles_test_expect <n>`, and `test_summary`
  fails if a different number of checks actually ran. Adding a test means moving
  the number beside it. That mechanism exists because a helper once handed its
  consumers paths that did not resolve outside the repository root, six safety
  checks silently stopped running, and the suite reported a smaller total that
  read like success. `tests/lib.sh` documents the rest of the house style.
- The shell scripts must stay **bash 3.2 and BSD sed** compatible: macOS ships
  bash 3.2 and GNU tooling is not available. CI runs shellcheck over
  `bootstrap.sh`, `rebuild.sh`, `lib/*.sh` and `tests/*.sh`.
- The scripts are bash; an agent's own shell here is often zsh. Test a library
  with `/bin/bash -c '. lib/x.sh; fn'`, never by sourcing it into your own shell.
- What gets installed is declared in two lists, not one: `home.packages` for
  nixpkgs and the `brews`/`casks` lists at the top of `home.nix` for Homebrew.
  Nothing may appear in both - two copies on `PATH` are resolved by an ordering
  the user never chose - and `tests/homebrew.test.sh` fails if one does. Node
  stays on the Nix side deliberately: a Homebrew node puts its global npm prefix
  outside the home directory.
- `flake.nix` has exactly two adjustable values, `user` and `homeDirectory`, one
  line each. `lib/flake-settings.sh` is the single definition of how they are
  read and rewritten; both scripts and the tests go through it. The architecture
  is deliberately **not** adjustable - both Darwin systems are built from the
  same source and the scripts detect which one they are on.
- Wherever a script offers a default, the default must be the **machine's current
  reality**, never the value already in the config. The repo this one replaces
  offered its configured machine name as the default, so pressing Enter silently
  renamed the Mac.

## Sharp edges found the hard way

- `ghostty` in nixpkgs is Linux-only. On macOS the attribute is `ghostty-bin`.
  `tests/packages.test.sh` catches this class of mistake for both architectures.
- Home Manager's Darwin app handling flipped default at `stateVersion` 25.11:
  `copyApps` (needs the macOS App Management permission, and aborts activation
  without it) instead of `linkApps`. This repo pins `linkApps` on purpose;
  `home.nix` and README.md explain the trade.
- Home Manager replaces `PATH` with a fixed list of Nix store paths before it
  runs an activation script, so an activation step cannot find a program the way
  a shell would. The Homebrew step locates `brew` by absolute prefix, preferring
  `HOMEBREW_PREFIX` when the environment carries one.
- `programs.zsh.initContent` defaults to order 1000, but Home Manager emits shell
  aliases at 1150 and syntax highlighting at 1200. The `~/.zshrc.local` include
  is at `lib.mkOrder 1500` so it genuinely runs last.
- `nix eval` on this flake prints an upstream warning about an `options.json`
  derivation built without proper context. It comes from Home Manager's own
  manual module and is not caused by anything here.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
