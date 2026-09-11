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
again. The marker is written **only after the handover is verified**, and what
it means is the one invariant everything here turns on:

> `$prefix/bin` and the library **exist** and belong to this account, and no
> directory the privileged step creates is somebody else's.

Not "the script ran once", and not "nothing present is unusable" - both of those
were tried and both re-opened the same loop, the second because a prefix whose
`bin` had been *deleted* has nothing present to complain about. Following
Homebrew's own uninstall instructions is how a real user gets there, and `ln`
then died on a bare errno mid-switch. `dotfiles_homebrew_unusable` counts a
missing path only when the marker is present, because before it nothing has been
promised and a bare prefix is exactly what the privileged step is for; a path
that is present and somebody else's counts either way. That asymmetry is read
once, in that function, and `dotfiles_homebrew_prefix_state` is the only boundary
any caller goes through - which is why the link step re-checks nothing and its
`ln` cannot fail that way any more.

**The existence half covers those two paths and no others, and that is not an
oversight to tidy up.** They are the only two `dotfiles_homebrew_prefix_link`
writes into, so they are all the `ln` guarantee needs - and every other directory
in the prefix belongs to Homebrew, which *deletes them itself*. In the pinned
source `Keg.must_exist_subdirectories` is `bin etc include lib sbin share opt
var/homebrew/linked`; `share/zsh` and `share/zsh/site-functions` are not on it,
so `Keg#unlink` rmdirs them once empty and
`Cleanup#prune_prefix_symlinks_and_directories` removes them unprompted on the
periodic cleanup this file already notes runs about monthly. Promising the whole
creation list made `brew uninstall gh` lock the prefix permanently, escapable
only by deleting the marker and re-bootstrapping for another password - so
widening it back for symmetry with the ownership half breaks the one promise
`rebuild.sh` exists to keep. `test_homebrews_own_pruning_does_not_lock_the_prefix`
is what stops that.

Creating is not promising, which is why the two lists in that function are
different sizes: `dotfiles_homebrew_prefix_directories` is what the privileged
step creates and what the ownership half inspects, and
`lib/homebrew-initialize-prefix.sh` creates it rather than restating it, because
two creation lists would be two different prefixes.

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
list. That list stays as short as the repo's actual needs: an acceptance path is
how the guard says yes, so one kept for a use that no longer exists is just a
gap waiting for a real invocation. A bash-array acceptance lived there while a
ported directory list still carried `bin/brew`; when that list went, so did the
rule, and `dirs=( brew install )` is flagged again. Reinstating it is one commit
whenever a real case comes back. Its remaining edge is
indirection: a path held in a variable and run as `"$BREW" install` is still
invisible to it. What keeps that from mattering is that no script here holds such
a path - the preflight reports what it found instead of returning it - not that
the check would notice.

`tests/homebrew.test.sh` covers the behaviour. It runs the Brewfile step against
a recording stand-in for `brew` and fails if it passes anything that could
uninstall or upgrade, if it lets either Homebrew cleanup variable through from
the environment, if a missing Homebrew produces a raw error rather than an
explanation, if it hands the Brewfile to a `brew` outside the prefix it was given
(that one asserts the stand-ins recorded no call at all, because a refusal that
had already exec'd `brew` would be a message rather than a guard), or if a tool
ends up installed by both Nix and Homebrew. It runs the
prefix steps against a stand-in prefix in a temp directory - created, marked,
re-run, linked, re-linked - and fails if an existing Homebrew is touched, if a
second run rewrites the marker, if the unprivileged step needs root, or if it
tries instead of refusing when the prefix is not ready. Four of those checks are
about the prefix it may not have: a directory the run cannot hand over must make
it refuse **and leave no marker**; a marked prefix the invoking account cannot
use must not come back `managed`; a marked prefix whose `bin` and library have
been deleted must be refused **with an explanation, never inside `ln`** - that
one asserts the absence of `ln:` in the output, because a raw errno is the
failure it exists to prevent; and a marked prefix whose `share/zsh` directories
Homebrew has pruned must still be `managed` and must still link, which is the
check that keeps the promise from widening back. The first two reach that state
with a mode that
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

The two questions are reconciled by **two guards, and both are required**. Each
asks `dotfiles_homebrew_is_managed_brew` - one function, so they cannot disagree
about what "ours" means - and each refuses rather than warning:

- **`dotfiles_homebrew_preflight`**, before Nix is installed and before the
  password. An Apple silicon Mac carrying an Intel Homebrew at `/usr/local` with
  that Homebrew's `shellenv` line in its profile has a Homebrew; a preflight that
  inspected only the architecture prefix said "no Homebrew in it", spent the
  password on a prefix nothing then used, and let the Brewfile step install every
  formula and cask into the other one without an error anywhere.
- **the Brewfile step**, on every switch. A preflight only runs when someone runs
  it, and a `shellenv` line added *after* a successful setup redirects every
  later rebuild. **The repository owner asked for this one explicitly, after
  being shown the cost - do not remove it as redundant with the preflight.** It
  is what makes the promise "nothing installs into a Homebrew this configuration
  does not manage" true at the moment of installing rather than at setup.

The Brewfile step is **given** the prefix it manages as its only argument rather
than working it out, and that is what keeps it testable: the stand-in tests point
both it and `HOMEBREW_PREFIX` at one temp directory, so the invariant under test
is "these two agree" rather than one hardcoded path. `home.nix` passes the same
value the prefix-setup step gets.

What the preflight refuses is **deliberately a superset** of "the Brewfile step
would have gone elsewhere", and the code comment says so rather than claiming an
equivalence it does not have. `dotfiles_homebrew_find`'s fallback is ordered and
the managed launcher does not exist yet at preflight time, so on Apple silicon
with `HOMEBREW_PREFIX` unset, an Intel Homebrew at `/usr/local` and no
`/opt/homebrew`, the preflight refuses a machine whose Brewfile step would have
found `/opt/homebrew/bin/brew` first and been right. On Intel the asymmetry runs
the other way and the guard is load-bearing: the managed prefix is `/usr/local`,
so a foreign `/opt/homebrew` wins the fallback even after setup. The superset is
the point - two Homebrews on one Mac leave the user's own PATH reaching the one
this repository did not fill, and the owner asked to be told and stopped.

This is also why the preflight checks in `tests/homebrew.test.sh` set
`HOMEBREW_PREFIX` explicitly rather than inheriting it: the preflight now reads
it, and a suite that left it alone would answer differently on a machine that
has Homebrew - which is every developer machine and every CI runner.
`dotfiles_run_preflight` takes the environment's prefix and the prefix to judge
as separate arguments for that reason, and the disagreement case is the one that
passes two different ones.

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
  runs in a different order on purpose: it settles `~/.dotfiles` and Homebrew's
  prefix in a preflight, asks `lib/nix-present.sh` for `nix` the moment step 1
  could have installed one, and only then repoints `~/.dotfiles` at step 2 and
  checks the account and home directory - because the interactive personalize
  steps in between are what make those two checks pass. That library is the
  **one** owner of the missing-`nix` refusal and it must stay ahead of step 5:
  a second copy of it further down would let a Mac whose switch can never run
  spend the password first. `tests/bootstrap.test.sh` drives the refusal with a
  `nix`-free PATH. Neither script may end a failed run on friendly advice.
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
  **That ordering is deliberately not asserted by a test, and a grep is not an
  acceptable substitute.** `tests/bootstrap.test.sh` once compared source line
  numbers for `sudo`, the Nix installer and the switch. It was wrong in both
  directions - moving the call into a function defined at the top fails it while
  preserving the order, and wrapping the same line in `if false` passes it while
  destroying it - so it was deleted rather than reworded. Do not re-add one. An
  end-to-end harness is not the missing alternative either: what cannot be stood
  in for is bootstrap.sh's own prefix *resolution*, which comes from `uname -m`
  and then inspects the real `/opt/homebrew` or `/usr/local`, so the result
  would depend on the machine running the suite. The library underneath it is
  entirely stand-in-able and is where the privileged step is actually covered -
  `tests/homebrew.test.sh` drives it against a temp-directory prefix. Keep
  coverage at that layer, where it is honest.
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
  Its write commits by **renaming a temp file created beside the target**, and
  all three parts of that carry weight: a copy over the original truncates
  first, so an interruption leaves the user an empty `flake.nix` and no
  configuration; a rename takes the temp file's permissions, so the target's
  mode is copied across explicitly; and it lands on the path
  `flake_settings_resolve` returns, so a symlinked `flake.nix` is written
  through rather than replaced. Beside the target because a rename is only
  atomic within one filesystem. `tests/flake-settings.test.sh` holds all three,
  the atomicity one by inode - an in-place rewrite keeps it, a rename does not.
- Wherever a script offers a default, the default must be the **machine's current
  reality**, never the value already in the config. The repo this one replaces
  offered its configured machine name as the default, so pressing Enter silently
  renamed the Mac.
- **Neovim's plugins are managed by lazy.nvim, and nothing in this repo installs
  them.** They install on the next `nvim` launch, pinned by the tracked
  `home/.config/nvim/lazy-lock.json`. The owner was offered an activation-time or
  rebuild-time `Lazy! sync` and chose per-launch install, so do not add one - a
  rebuild would then need a writable plugin tree and a network, and `rebuild.sh`
  exists to refuse before it writes. Let a real install write the lock rather
  than hand-editing it, but revert every line the change did not intend: `Lazy!
  sync` bumps *all* plugins, so adding one plugin the lazy way moves nine other
  pins as a side effect.
- **`nvim-treesitter` is deliberately absent.** The `neovim` in `home.packages`
  ships the `markdown` and `markdown_inline` parsers `render-markdown.nvim`
  reads a buffer with, so they are pinned by `flake.lock` alongside the editor
  that loads them; nvim-treesitter's parsers are compiled at run time and pinned
  by nothing. Anyone adding it anyway needs `branch = 'main'` and the
  tree-sitter CLI, because its `master` is broken on the pinned Neovim. Check
  the claim rather than inheriting it when nixpkgs moves - the parsers live in
  `lib/nvim/parser/` of the built `neovim`.
- **`markdown-preview.nvim` is declared with `ft` and no `cmd`, on purpose.**
  `home/.config/nvim/lua/plugins/markdown.lua` carries the mechanism and why a
  `cmd` stub makes the failure worse rather than better; read it there rather
  than restating it here, because two copies of that reasoning drifting apart is
  exactly what went wrong upstream of this port.

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
- **Exercising this Neovim config means driving an isolated one, not `nvim`.**
  `~/.config/nvim` is a symlink to the activated Home Manager generation, so a
  plain `nvim` run anywhere on the machine loads some other checkout's config and
  writes its `lazy-lock.json` back into that checkout. Point `XDG_CONFIG_HOME` at
  a scratch directory whose `nvim` entry links to the working tree's
  `home/.config/nvim`, give it scratch `XDG_DATA_HOME`, `XDG_STATE_HOME` and
  `XDG_CACHE_HOME`, and check `stdpath('config')` resolves where you meant before
  letting lazy install anything. Keep that scratch path **short**: `vim.loader`
  names its bytecode cache after the percent-encoded absolute path of every file
  it compiles, so a deep temp directory fails with `ENAMETOOLONG` from inside
  `write_cachefile` and the failure reads like a plugin error. `vim.fn.system`
  also hangs in `--headless`; run the HTTP check from the shell alongside nvim
  instead.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
