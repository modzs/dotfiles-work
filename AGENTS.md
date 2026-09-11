# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## The design rule

**This repository must not reconfigure a Mac the user does not administer, and
must not take anything away from one the user does.**

That is the entire reason it exists, separately from a personal dotfiles repo.
It is for work Macs, where a configuration that renames the machine or prunes
system packages is not merely rude but dangerous - the setup this one replaces
would have uninstalled an employer's security agent.

The rule has been restated twice, both times because the owner asked for
something the previous wording forbade, and both times the honest move was to
narrow the claim rather than quietly enforce less.

It began as "nothing this repository does may affect anything outside the user's
home directory", and for a while that was literally true. Then this
configuration started **driving** Homebrew: `home.nix` generates a Brewfile and
an activation step runs `brew bundle install` against it on every switch, which
writes into Homebrew's prefix and puts casks in `/Applications`.

Now it also **installs** Homebrew. Homebrew's source is a pinned flake input
(`brew-src`), `home.nix` patches the store copy and generates a `brew` around
it, `bootstrap.sh` creates the standard prefix once behind one announced `sudo`,
and an activation step links the two together on every switch. The owner
administers this Mac and asked for the standard prefix - `/opt/homebrew` on
Apple silicon, `/usr/local` on Intel - accepting a second one-time password
prompt in exchange for bottles and casks that actually work. The technique is a
port of [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)'s, taken
without its module, for the reason in the next section.

So the heading above is what is left, and it is now the *second* half of it that
carries most of the weight. What follows from it, and still holds without
exception - this repo must never:

- rename the machine, or set any `networking.*` or `system.defaults` option;
- write to `/etc`, `/Library`, or `/usr` and `/opt` outside the single Homebrew
  prefix it creates. Creating that prefix and giving it to the user is the one
  privileged act, it happens once, and it happens in `bootstrap.sh`;
- **convert, migrate or delete a Homebrew it did not install.** A prefix already
  holding one is reported and the run stops - at the preflight before Nix is
  installed, again as root immediately before writing, and again in the
  activation step. nix-homebrew has an `autoMigrate` that deletes an existing
  Homebrew repository while keeping its packages; that option is deliberately
  not ported, and the `nuke-homebrew-repository` tool it drives is not either.
  This is the single most dangerous thing anyone could add here;
- **install, update or remove any other system-wide package manager**, or
  install Homebrew the way Homebrew does. Nothing here ever runs `brew.sh`'s
  installer or clones Homebrew at run time: the whole point of the flake input
  is that `flake.lock` decides the version, so there is no self-updating git
  checkout in the prefix for `brew update` to fast-forward;
- **ask Homebrew to remove anything.** There is no `cleanup`, no `--zap`, no
  `brew uninstall`, and there must never be one; the step also unsets the two
  `HOMEBREW_BUNDLE_*_CLEANUP` variables, which exist only to turn a bundle
  install destructive. On this machine Homebrew is the user's general-purpose
  package manager, so a declarative cleanup would delete software installed by
  hand for reasons this repo knows nothing about - a security agent among them.
  State it as "asks for", not as "nothing is ever removed": every `brew install`
  ends with Homebrew's own periodic cleanup, which about monthly runs
  `autoremove`, so a rebuild that installs something can be the command that
  triggers it. That is Homebrew's standing behaviour on the user's own machine,
  it reaches only unrequested formula dependencies and never casks, and it is
  deliberately left alone - suppressing it would reverse a Homebrew preference
  of the user's, the same overreach as clearing `HOMEBREW_NO_AUTO_UPDATE`. The
  two `_CLEANUP` variables are different in kind, which is why those are unset;
- manage other user accounts, sudoers, sshd, or PAM;
- **run `sudo` more than once, or anywhere but `bootstrap.sh`.** There are now
  exactly two password prompts in a bootstrap and there must never be a third:
  the Determinate installer's, which happens inside the installer rather than
  here, and `sudo lib/homebrew-initialize-prefix.sh`, which creates the prefix
  and chowns it to the user. That script escalates nothing itself - it expects
  to be root already - so the escalation stays on one line, at one call site,
  where it can be read. **`rebuild.sh` still never asks for a password**, and
  keeping that true is the point of doing the privileged work once: everything
  a rebuild touches is inside `$HOME` or inside a prefix the user now owns.
  One thing this repo drives can still produce a prompt, and the claim has to be
  stated that way rather than as "a rebuild never asks": `--force` lets a cask
  replace an app already in `/Applications`, and when that app is owned by
  someone else Homebrew falls back to `sudo` to take ownership before removing
  it. That is Homebrew asking, in a step this repo asked for - so the promise is
  that nothing here runs `sudo` itself except that one line.

One consequence worth knowing before changing anything on an Intel Mac:
`/usr/local` already exists on every Mac and is shared with everything else
installed there, and initializing that prefix creates `bin`, `lib`, `share` and
their siblings and chowns **the ones it created** to the user. That is why
`/usr/local` is named in the rule above rather than excluded from it.

It is also where this port stops short of Homebrew's own installer, which chmods
and chowns whatever it finds already in the prefix. A directory that is there
and is not the user's makes the prefix `unusable`: the run refuses and names the
paths, at the preflight, again as root, and again in the activation step. There
is no branch that takes one over, and adding one would be the same mistake as
`autoMigrate`. The check reads ownership and mode with `stat` rather than asking
`[ -w ]`, because the privileged step runs as root, for whom `[ -r ]`, `[ -w ]`
and `[ -x ]` are true of every path that exists - a probe written that way
answered "writable" about directories the user could not touch, and the marker
went down anyway, which left a prefix that could never be bootstrapped or rebuilt
again. The marker is now written **only after the handover is verified**, so it
is proof that the prefix is the user's rather than a record that the script
reached the end, and `dotfiles_homebrew_prefix_state` will not say `managed`
about a prefix the invoking account cannot use however many markers it carries.

The rule is enforced mechanically, not by memory. `tests/safety.test.sh` fails if
the flake grows a nix-darwin input, if a system-level option namespace appears in
the evaluated configuration, if a managed file targets a path outside `$HOME`, if
any tracked script gains a privilege escalation other than the one permitted
line, if any script this repo runs invokes `brew` or carries a Homebrew
installer URL in its text, or if the built artifact embeds any Homebrew path but
the exact six this configuration manages.

Three of those checks carry a narrowing and each one comes with a fixture test,
because a guard with an exception in it is the kind that widens in silence:

- the **flake input** check permits `brew-src` by identity rather than by name -
  it must resolve to `Homebrew/brew` and be `flake = false` - while `nix-darwin`,
  `darwin` and `nix-homebrew` stay banned outright;
- the **privilege** check permits exactly one `sudo`, only in `bootstrap.sh`, and
  only immediately followed by `$DIR/lib/homebrew-initialize-prefix.sh`. A second
  one in the same file, the same line in another file, a flag between `sudo` and
  the path, or any other target all still fail;
- the **artifact path** check now asserts an exact set of six paths rather than a
  maximum count, and its scope has grown to include the prefix-setup step, the
  library that step sources and the generated `brew`. Leaving those out is
  precisely how it would have gone quiet, since they are where every new path
  lives. The patched Homebrew tree is deliberately out of scope: it *is*
  Homebrew, and every path in it is upstream's.

Both the privilege and Homebrew checks tokenize rather than grep, so *explaining*
Homebrew or `sudo` in a comment is fine and several of these scripts do;
invoking one is what fails. The Homebrew one goes further and looks at position,
so naming a path is allowed and only a command word counts - `lib/homebrew-present.sh`
has to ask whether `/opt/homebrew/bin/brew` exists. It is run against fixture
scripts with known answers, so narrowing it cannot quietly turn it into a no-op.
It decides that question in the direction that fails closed: a `brew` token
counts as an invocation unless something makes it an argument, and the list of
those is short and belongs to this repo. The earlier shape asked the opposite,
listing the tokens after which `brew` counted as a command, and `if brew`,
`while brew`, `exec brew` and `command brew` all walked through the gaps in that
list. The newest entry on the argument list is a bash array literal, which the
ported prefix-directory lists needed while one of them still carried `bin/brew`
(`lib/homebrew-initialize-prefix.sh` no longer does, since the branch that
chowned pre-existing directories is gone, but the rule stays - the lists are
upstream's and move); a nested command substitution opens a group of its own, so
`dirs=( $(brew list) )` is still caught. Its remaining edge is
indirection: a path held in a variable and run as `"$BREW" install` is still
invisible to it. What keeps that from mattering is that no script here holds such
a path - the preflight reports what it found instead of returning it - not that
the check would notice.

`tests/homebrew.test.sh` covers the behaviour. It runs the Brewfile step against
a recording stand-in for `brew` and fails if it passes anything that could
uninstall or upgrade, if it lets either Homebrew cleanup variable through from
the environment, if a missing Homebrew produces a raw error rather than an
explanation, or if a tool ends up installed by both Nix and Homebrew. It runs the
prefix steps against a stand-in prefix in a temp directory - created, marked,
re-run, linked, re-linked - and fails if an existing Homebrew is touched, if a
second run rewrites the marker, if the unprivileged step needs root, or if it
tries instead of refusing when the prefix is not ready. Two of those checks are
about the prefix it may not have: a directory the run cannot hand over must make
it refuse **and leave no marker**, and a marked prefix the invoking account
cannot use must not come back `managed`. They reach that state with a mode that
denies its own owner write, because creating a root-owned directory would need
root and no test here may have it - the code decides both by ownership and mode,
so one stands in for the other. The stand-in prefix is possible because the
library takes the prefix as an argument; there is no environment variable that
moves it, and there must not be one.

Two questions about "where is Homebrew" live in this repo, they are genuinely
different, and each now has exactly one implementation. **Where this
configuration's Homebrew belongs** is decided by the architecture alone - by
`lib/homebrew-present.sh` at run time and by `home.nix` at evaluation time, two
mechanisms (`uname -m` and `pkgs.stdenv.hostPlatform`) that must agree, and a
test compares them. **Where the Brewfile step looks** is a search that still
honours `HOMEBREW_PREFIX`, which is also the lever every stand-in test in that
file depends on; both activation steps source the library for it rather than
carrying a copy, and a test asserts they source the same file. That search used
to exist twice and the copies drifted - an unquoted `for` over a
space-separated string meant a `HOMEBREW_PREFIX` containing a space split into
two paths that do not exist - so do not reintroduce a second copy. Read both
files before changing the structure of the configuration; they explain what each
check asserts and why a grep would not do.

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
  The rule binds hardest on the one step that writes outside `$HOME`.
  `bootstrap.sh` creates the Homebrew prefix at step 5, after
  `flake_settings_check_machine` and before the switch, so by the time the
  password is asked for, every refusal the run can make has already been made.
  It cannot be run end to end by a test - it installs Nix - so
  `tests/bootstrap.test.sh` asserts that ordering against the script's source,
  and says in place why that one check is allowed to read source when the rest
  of the suite runs code.
- **The Homebrew machinery, in the order a reader needs it.** `brew-src` is a
  pinned, non-flake input; `home.nix` patches the store copy (`patchedBrew`) and
  builds a launcher around it (`binBrew`); `lib/homebrew-initialize-prefix.sh`
  creates the prefix once as root; `lib/homebrew-present.sh` holds every rule
  about where the prefix is and what state it is in, and is **sourced out of the
  store** by `home.nix`'s setup step so those rules exist once rather than
  twice. Three things are worth knowing before changing any of it:
  `patchedBrew`'s three patches each assert their target exists, so a Homebrew
  that renames one fails the build instead of losing the patch silently;
  `binBrew` slices the tail of upstream's own `bin/brew` out of the pinned source
  rather than vendoring a copy, and asserts the shape it slices; and nothing may
  use `builtins.readFile` on a derivation, because import-from-derivation would
  break CI's `nix build --dry-run` of the Intel configuration on an Apple
  silicon runner.
- **A successful run has to be legible.** `lib/install-report.sh` is what
  `bootstrap.sh` says at the end and, through
  `install_report_rebuild_verdict`, what `rebuild.sh` says after a successful
  switch - two callers share it. `tests/install-report.test.sh` drives it
  directly. Nothing this repo writes puts the profile on `PATH` - a line the
  Nix installer adds to `/etc/zshrc` does - so the report probes what a fresh
  login shell would really see and warns when it would see nothing. It names
  that file and never writes to it; a check that cannot answer must read as
  unverified, never as fine.
- **Never activate a configuration while testing, and no test may.** `nix flake
  check`, `nix build .#default` and `nix eval` are safe; `home-manager switch`,
  `./rebuild.sh` and `./bootstrap.sh` rewrite a real home directory. Building an
  activation package is not activating it, and reading the built `activate`
  script as an artifact is safe - that is how the activation order is asserted.
  Pointing `homeDirectory` at a temp directory does **not** make activating
  safe; see the sharp edge below for why.
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
- Homebrew's own version is a **third** pinned thing, in `flake.lock` rather than
  in either list. The tag in `flake.nix` is the one nix-homebrew pins, and that
  is not incidental: `patchedBrew`'s patches were written against that shape, and
  one of them is a `--replace-fail`. Moving the tag is a deliberate, testable
  change - `nix build .#default` is the gate - not a routine bump. Note that
  nix-homebrew's own `sed` that embeds the version no longer matches anything in
  6.0.22, so this repo overrides `set-homebrew-version-from-git` instead and
  says so where it does it.
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

- **A built `activate` script holds absolute paths that do not come from
  `homeDirectory`, so redirecting it does not redirect them.** The complete set,
  as of the pinned Home Manager: `${NIX_STATE_DIR:-/nix/var/nix}/profiles/per-user/$USER`
  and the matching `gcroots/per-user/$USER`, both derived from `$USER`;
  `/bin/launchctl`, invoked in domain `gui/$UID`; `/etc/profiles/per-user/`,
  read-only; and `/bin/bash`, `/bin/readlink`, `/bin/rsync`, `/bin/dirname`.
  The per-user Nix state paths are destructive: when the pre-Nix-2.14 layout is
  present, `migrateProfile` runs
  `rm "$oldProfilesDir/home-manager" "$oldProfilesDir"/home-manager-*` against
  the **real** user's profile, and it runs *before* the `USER` and `HOME` sanity
  checks, so neither check can protect anything. The `launchctl` path is inert
  here only because this configuration declares no launchd agent; it re-arms
  silently the day one is added, with nothing failing loudly at that moment.
  This is why no test may activate: a guard would have to keep that list
  complete forever, and `./tests/run.sh` is documented in HOW-TO.md under "See
  what would happen, without changing anything".
  Method lesson, because it is what produced the false claim this replaces: a
  probe whose pattern can only match the shape you expect cannot disconfirm
  anything. "Every path derives from `homeDirectory`" was established with a
  grep for `/Users` paths, which by construction could never have found the
  `/nix/var/nix` counterexample that makes it false.
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
- Home Manager breaks an unconstrained DAG tie **by attribute name**, and
  `homebrewBundle` sorts before `homebrewPrefix`. The prefix step is what puts a
  `brew` in the prefix, so without the explicit `entryAfter [ ... "homebrewPrefix" ]`
  on the bundle step the order is exactly backwards, and a first switch reports a
  missing Homebrew that the very next step was about to install. This is the same
  trap that already required the `linkGeneration` edge.
- A prefix created by this repo carries `.managed_by_nix_darwin`, which is
  **nix-homebrew's marker filename and not a leftover**. The marker is an on-disk
  contract between whatever set a prefix up and whatever finds it later, so
  matching the name means nix-homebrew and this repo hand the same prefix back
  and forth instead of each initializing over the other. It says `nix_darwin`
  because nix-homebrew wrote it first; there is still no nix-darwin input here
  and `tests/safety.test.sh` still fails if one appears.
- `nix eval` on this flake prints an upstream warning about an `options.json`
  derivation built without proper context. It comes from Home Manager's own
  manual module and is not caused by anything here.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
