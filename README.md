# dotfiles-work

A small, rarely-changed dotfiles configuration for **a work Mac**.

It sets up a shell, an editor, a terminal and a handful of command-line tools:
most of it inside your home directory, plus Homebrew and a short list of
formulae and casks. It is deliberately separate from, and much smaller than, a
personal dotfiles repo, because a work Mac is a machine you cannot easily repair
and should not casually reconfigure. The next section is exact about where the
line falls.

## What this touches, and what it does not

This is the whole point of the repository, so it comes first, and it is written
to be read by someone deciding whether it may run on a machine they are
responsible for.

There are two separate things here, and the honest answer is different for
each: **this configuration**, which is everything in this repository, and
**installing Nix**, which `bootstrap.sh` hands to a third-party installer once.

**Most of what this configuration does is confined to your home directory. Two
parts are not, and both are about Homebrew.**

**It installs Homebrew**, once, during `./bootstrap.sh`. Homebrew's own source
code is pinned in `flake.lock` and lives in the Nix store; what `bootstrap.sh`
creates on the machine is Homebrew's standard prefix - `/opt/homebrew` on Apple
silicon, `/usr/local` on Intel - which it then gives to your account. That step
needs your password, and it is the second and last time anything here asks for
one. If a Homebrew you did not get from this repo is already there, it stops and
tells you what it found; it never converts, migrates or deletes one.

**It then drives that Homebrew.** It generates a list of formulae and casks, and
on every rebuild it asks Homebrew to install what is on the list. Homebrew
installs into the prefix above, and casks put real applications in
`/Applications`. Both are outside your home directory.

Neither is an accident, and this section says so rather than claiming a
containment that no longer holds. You need admin rights on this Mac for any of
it to work.

### What this configuration writes, and the two places it reaches further

| This configuration does | This configuration does not |
| --- | --- |
| Install command-line tools for your account from Nix, inside your home directory | Write anywhere outside your home directory except one Homebrew prefix. It creates that prefix once, and after that everything it writes there it writes as you. Where a cask goes beyond that is the cask's doing: a `pkg` cask hands its payload to the macOS installer, which can write to `/Library` and prompt for a password. That only happens for a name you put on the list yourself |
| Create Homebrew's standard prefix once and hand it to your account | Touch a Homebrew it did not install. If one is already there it stops and says so - it never converts, migrates or deletes one, see below |
| Install Homebrew itself, from the exact version pinned in `flake.lock` | Run Homebrew's installer, or leave a git checkout in the prefix that can update itself, see below |
| Ask Homebrew to install a fixed list of formulae and casks | Uninstall *anything*, or let the environment ask it to - see below |
| Write config files under `~/.config`, `~/.zshrc`, `~/Applications` | Change the computer's name, network settings, or macOS system settings |
| Ask for your password **twice during `./bootstrap.sh`** - once for Nix, once for Homebrew's prefix | Ask for your password during `./rebuild.sh`, or run `sudo` anywhere but that one line in `bootstrap.sh` - though a cask replacing an app you do not own can make *Homebrew* ask, see below |

Three of those deserve to be spelled out.

**It asks Homebrew to uninstall nothing.** Homebrew's "bundle" mechanism can be
run in a mode that uninstalls whatever is not on the list. This configuration
passes no flag that asks for it, and it goes one step further: that mode can
also be turned on from the environment, by `HOMEBREW_BUNDLE_INSTALL_CLEANUP` or
`HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP`, so the step unsets both before it runs
Homebrew. Whatever is exported on the machine, in a shell profile or by a
managed configuration profile, no rebuild asks Homebrew to remove software. The
test suite runs the step against a stand-in for `brew` and fails if it ever
passes a flag that could uninstall, or if either of those two variables survives
into Homebrew's environment.

That is a claim about what this repository asks for, and it is worth being exact
about the difference between that and what Homebrew does on its own. Every
`brew install` on this Mac - yours, typed by hand, or this one - finishes by
checking whether a routine cleanup is due, and roughly monthly that cleanup runs
`brew autoremove`. So a rebuild that installs something new can be the command
that triggers it. That is Homebrew's standing maintenance on this machine rather
than anything this configuration introduces, which is why the step leaves it
alone: switching it off here would give this Mac a maintenance policy your other
Macs do not have, and it would be reversing your own Homebrew setting to do it.

Its reach is narrow, and the narrowness is the point. `autoremove` considers
formulae only, never casks, and never a formula you installed on request - only
ones that arrived as dependencies and are no longer needed by anything
installed. Software you installed deliberately stays. If you would rather
Homebrew never did this at all, that is a Homebrew setting, `HOMEBREW_NO_AUTOREMOVE`,
and it is yours to set.

There is one thing it *will* replace, and it is worth being exact about. The
step passes `--force`, so a cask is allowed to claim whatever is already
sitting where it installs. For the two application casks on the list in
`home.nix` - today WezTerm and Ghostty - that means an app of that name already
in `/Applications` is replaced by Homebrew's copy, however it got there.

Replacing an app is also the one thing that can make a password prompt appear
mid-rebuild, and it is worth knowing why. `./rebuild.sh` never runs `sudo` and
never asks for a password itself - the only `sudo` in this repository is the one
line in `./bootstrap.sh` that creates Homebrew's prefix. But Homebrew removes the
app it is replacing, and if that app belongs to someone else - deployed by your
employer's management software, owned by `root` - the plain removal fails, and
Homebrew falls back to taking ownership with `sudo`, which prompts. So: a rebuild
does not ask for your password, and a cask replacing an app you do not own can
cause Homebrew to.

The third cask, `claude-code`, installs no app: it puts a `claude` command on
Homebrew's `bin` path, and there `--force` mostly does not overwrite. The exact
rule, because it decides whether your rebuild stops or your file disappears. If
something already sits at that path and it resolves to a real target, it is
replaced only when it is a symlink pointing into that cask's own storage;
anything else - a regular file, or a working link to something unrelated - makes
the install refuse, which fails the rebuild and keeps failing until you move it
aside yourself. The exception is a *broken* symlink: Homebrew tests whether the
target exists, a dangling link answers no, and it is replaced silently. Nothing
whose name is not on the cask list is touched at all.

**It installs Homebrew, and it will not touch one you already have.** This is
the newest thing here and the one most worth understanding.

Homebrew's source is a pinned input of this flake, exactly like nixpkgs: a
specific commit, recorded in `flake.lock`, unpacked into the Nix store. What
`./bootstrap.sh` does on the machine is create the standard prefix and `chown`
it to you - the same layout Homebrew's own installer creates, which is what
makes prebuilt bottles and casks work. It never downloads and runs
Homebrew's installer script, and it never leaves a git checkout in the prefix.

If the prefix already contains a Homebrew this repository did not put there,
**nothing happens**. `./bootstrap.sh` stops before Nix is installed and before
any password prompt, names the files it found in the way, and tells you that you
can remove that Homebrew yourself if you want this repo to manage it instead.
There is no option to convert or migrate it, deliberately: on a work Mac,
deleting a package manager's tree is not a decision a setup script should make.

Because Homebrew's code is a read-only symlink into the Nix store, **Homebrew
cannot update itself here**, and the self-update path is patched out as well. A
`brew upgrade` still upgrades your *packages* normally; what is pinned is
Homebrew the program, and it moves when `flake.lock` moves and at no other time.
That is a change from how a hand-installed Homebrew behaves, and it is the point:
it is the same guarantee the rest of this configuration already gives.

`HOMEBREW_NO_AUTO_UPDATE` is still left exactly as it finds it - this repo does
not set it and does not clear it - because it is yours to decide and a slow or
proxied network is a good reason to have set it. With a pinned Homebrew there is
simply nothing for an auto-update to fast-forward.

If the prefix goes missing later, `./rebuild.sh` stops at that activation step
and points you back at `./bootstrap.sh` - everything Nix installs is already in
place by then, your shell and editor and git config included, and only the
formulae and casks are missing.

**Everything else really is confined.** This is a
[standalone Home Manager](https://nix-community.github.io/home-manager/)
configuration with no `nix-darwin`, which means it has no way to express a
machine name, an `/etc/sudoers` edit, an `sshd_config`, a system-domain macOS
default, or another user account - those settings do not exist in it, so they
cannot be set by accident or by a future change. That stays true even though the
Homebrew mechanism above is a port of
[nix-homebrew](https://github.com/zhaofengli/nix-homebrew), which ships only as a
`nix-darwin` module: the technique was rewritten for standalone Home Manager
rather than the module imported, precisely so this paragraph keeps being true.
`tests/safety.test.sh` asserts that mechanically against the evaluated
configuration and the built artifact - including that the flake has no
`nix-darwin` input and that exactly one `sudo` exists in the whole repository -
and `tests/homebrew.test.sh` asserts the Homebrew claims above by executing
them.

### Installing Nix is a system-level install, and it does write outside `$HOME`

This is the one step `bootstrap.sh` does not do itself. It runs the
[Determinate Systems installer](https://install.determinate.systems), once, and
that is the first of the two password prompts in the setup - the other is
Homebrew's prefix, above. Nothing in this repository can do any of the following;
the installer does, and it is worth knowing before you show this repo to whoever
administers your Mac:

| Path | What it is |
| --- | --- |
| `/nix`, on its own APFS volume | the Nix store: every package installed for your account |
| `/etc/nix/` | the daemon's configuration |
| `/etc/synthetic.conf` | the entry that lets `/nix` exist at the root of the disk |
| `/Library/LaunchDaemons/systems.determinate.*.plist` | the build daemon that runs in the background |
| a block appended to `/etc/zshrc` and `/etc/bashrc` | what puts `nix`, and the tools this configuration installs, on the `PATH` of new shells |

So "it only touches my home directory" is true of the configuration apart from
the Homebrew prefix above, and it is not true of installing Nix at all. After the
install, the store, your profile generations and everything else Nix does for
you belong to your account - and so does the Homebrew prefix - and nothing else
on the machine is touched again.

That last row is the one to remember on a managed Mac: the `/etc/zshrc` block
is what makes any of this reachable from a shell, and it is a system file this
repository will never write to. `bootstrap.sh` and `rebuild.sh` both check
whether a fresh login shell can actually find what is installed, and say so
plainly when it cannot - they can tell you where to look, and they cannot fix
it for you. If management software has dropped that block, the repair that is
yours to make is a `PATH` line in `~/.zshrc.local`, below.

> **Check with your employer before installing anything.** The paragraphs above
> are technical statements about what this configuration does. They are not
> permission to install software - Nix or Homebrew - on a machine your employer
> owns. This repo now installs both, and needs admin rights to do it.

## What you get

From **Nix**, pinned by `flake.lock`:

- **zsh** with autosuggestions, syntax highlighting and a
  [starship](https://starship.rs) prompt
- **neovim**, configured, with the plugin set in `home/.config/nvim`
- **git**, wired to include untracked local files for your identity
- `ripgrep`, `fd`, `fzf`, `jq`, `lazygit`, Node, and the Hack Nerd Font

**Homebrew itself**, pinned by `flake.lock` like everything else - and from it,
whatever it resolves at the time you rebuild:

- `herdr` and `gh`
- **WezTerm**, **Ghostty** and **Claude Code**, as casks

The two halves are declared separately in `home.nix` and nothing appears in
both. The trade between them is real: the Nix half is reproducible - the same
`flake.lock` gives the same versions on any machine, forever - and the Homebrew
half is not, because a Brewfile names a formula and Homebrew decides the
version. What the Homebrew half buys is that its applications land in
`/Applications` like any other Mac application, where Spotlight and Launch
Services find them.

None of your packages update on their own. This is meant to be installed once
and left alone, and an update is something you do deliberately. That holds for
both halves: a rebuild installs whatever on the Homebrew list is missing and
skips what is already installed, leaving it at the version it is, so upgrading a
formula or a cask on the list stays something you ask for with `brew`. The
exception is a dependency - installing a new name may bring an outdated library
it needs up with it, which is Homebrew resolving its own requirements rather
than anything this configuration asks for.

Homebrew itself is pinned too, and that is different from a hand-installed one.
Its code is a read-only symlink into the Nix store, so it cannot update itself and
`brew update` has nothing to fast-forward. It moves when you change the tag in
`flake.nix` and run `./rebuild.sh`, and at no other time. Your *packages* are
still unpinned - a Brewfile names a formula and Homebrew picks the version - so
`brew upgrade <formula>` works exactly as it always did.

## Prerequisites

- macOS on Apple silicon **or** Intel. Both are first-class here - the
  architecture is detected, not configured.
- **Admin rights on the Mac**, and the ability to install software on it.
  `./bootstrap.sh` asks for your password twice: once for Nix, once to create
  Homebrew's prefix. If your employer's policy does not allow that, this repo
  cannot be used.
- **No pre-existing Homebrew in the standard prefix.** This repo installs its
  own and will not take over one it did not create; if it finds one,
  `./bootstrap.sh` stops and tells you. Removing it first is your call, and
  Homebrew documents how. There is also no way to turn the Homebrew half off:
  emptying the `brews` and `casks` lists in `home.nix` leaves the step with
  nothing to install, but the step still runs.

## Setup

See [HOW-TO.md](HOW-TO.md) for step-by-step setup and the commands to apply changes.

## Making it yours

See [HOW-TO.md](HOW-TO.md) for instructions on adding tools, changing your account or home directory, and editing the configuration.

## The untracked local files

This repository is public and employer-agnostic: nothing specific to a company
belongs in it. Anything of that kind goes in files that live in your home
directory and are never committed. `bootstrap.sh` creates the first two with
comments explaining what they are for.

### `~/.zshrc.local`

Sourced last by `~/.zshrc`, so anything here wins over the tracked
configuration. This is where a corporate environment goes:

```sh
# A network that intercepts TLS needs Node to trust its own CA.
export NODE_EXTRA_CA_CERTS="$HOME/certs/your-ca.pem"

# A proxy.
export HTTPS_PROXY="http://proxy.example.invalid:8080"
export HTTP_PROXY="$HTTPS_PROXY"
export NO_PROXY="localhost,127.0.0.1"

# An internal package registry.
npm config set registry https://registry.example.invalid/
```

`NODE_EXTRA_CA_CERTS` is worth calling out: corporate networks commonly
intercept TLS, and without it every HTTPS request from Node - `npm install`
included - fails with a certificate error. This repo does not set it, because
the correct value is a path only your machine knows.

This file is also where the `PATH` repair goes if the Nix block has gone
missing from `/etc/zshrc` and you cannot put it back:

```sh
export PATH="$HOME/.nix-profile/bin:$PATH"
```

Both scripts source this file when they check reachability, so a fix here is
recognised rather than warned about.

### `~/.gitconfig.local` and `~/.gitconfig.work`

Your git identity goes in untracked files in your home directory. See
[HOW-TO.md](HOW-TO.md) for the setup commands and how to apply a work identity
to repositories under `~/work` only.

The tracked configuration sets no name or email at all - an identity committed
here would follow every clone of a public repo, and on a work machine it is not
this repository's business.

Note: this configuration writes `~/.config/git/config`, and git reads `~/.gitconfig`
**after** that. If your Mac already had a `~/.gitconfig` with an identity in it,
that identity still wins. Use `git config --show-origin --get user.email` to see
which file git is actually using.

## Things worth knowing

### Where the applications go

WezTerm and Ghostty are application casks, so they install into `/Applications`
exactly like any application you download yourself. Spotlight indexes them,
`open -a WezTerm` works, and they appear in the Dock and in Launchpad without
anything special being done to them.

Claude Code is a cask too, but not an application one: it installs a single
`claude` executable onto Homebrew's `bin` path. Look for it in a terminal, not
in Launchpad - there is no bundle for Spotlight or the Dock to find.

That was not true of the arrangement this replaced, where they came from Nix and
were symlinked into `~/Applications/Home Manager Apps`. Symlinked bundles launch
from Finder but are not reliably indexed, so ⌘-Space did not find them.

If you add a GUI application from nixpkgs, it goes back to being symlinked:

```nix
targets.darwin.copyApps.enable = false;
targets.darwin.linkApps.enable = true;
```

Those two lines are set that way on purpose and `tests/packages.test.sh` holds
them there. Home Manager's default from `stateVersion` 25.11 is the other one,
`copyApps`, which copies the bundles so Spotlight indexes them - but copying
requires the macOS **App Management** permission for your terminal, and when it
cannot get that permission it aborts the entire activation. On a machine whose
privacy settings someone else administers that permission may not be grantable
at all, and losing your whole shell setup over one application is a bad trade.

### Globally installed npm packages

`npm install -g` writes into `~/.npm-global`, which is on your `PATH`. Node
itself comes from nixpkgs and lives in the read-only Nix store, so npm needs a
writable prefix somewhere - and the only place this configuration will put one
is inside your home directory.

### Homebrew's prefix is created once, by `./bootstrap.sh`

Creating it is the only privileged thing this repo does, and it happens at step
5 of the bootstrap - after every check that could refuse the run, and before the
first switch. Two rebuild-time steps then depend on it: one links Homebrew's code
and launcher into the prefix, and the next hands `brew` the generated Brewfile.
Both run as you, in a prefix you own, which is why `./rebuild.sh` never asks for
a password.

If the prefix goes missing or stops belonging to you, `./rebuild.sh` stops at the
first of those steps and points you back at `./bootstrap.sh`; everything Nix
installs has already been written by that point, so your shell and editor are
configured either way.

Homebrew still needs to be on your `PATH` for the tools it installs to be usable,
and this repo does not put it there - that is your `~/.zprofile`, with Homebrew's
own line:

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"   # /usr/local/bin/brew on Intel
```

Nothing here writes that for you, and a rebuild does not depend on it: this repo
finds `brew` by its prefix rather than through `PATH`, so a rebuild can succeed
on a machine where your shell still cannot see `gh`. If that happens, the missing
piece is that line.

### Editing neovim and wezterm config

`~/.config/nvim` and `~/.config/wezterm` are symlinks straight into this
repository, not copies in the Nix store, so you can edit them and see the change
immediately. See [HOW-TO.md](HOW-TO.md) for details.

### Intel Macs

Fully supported, and CI evaluates the Intel configuration on every change.
Note that nixpkgs 26.05 - the release this repo pins - is the **last** one to
support `x86_64-darwin`. An Intel Mac can stay on this pin indefinitely, which
suits a configuration meant to be left alone; a future nixpkgs bump will be an
Apple-silicon-only move.

### Rolling back and removing

See [HOW-TO.md](HOW-TO.md) for the commands to undo changes or remove this configuration.

## Repo tour

| Path | What it is |
| --- | --- |
| `flake.nix` | The two adjustable settings, the pinned Homebrew version, and the configuration for both architectures |
| `home.nix` | Everything that gets installed and configured, from both Nix and Homebrew |
| `home/.config/` | Editor and terminal config, symlinked live into `~/.config` |
| `bootstrap.sh` | One-time setup: Nix, settings, local files, first switch |
| `rebuild.sh` | Every later change |
| `lib/` | The shared shell functions both scripts use |
| `tests/` | Behaviour tests, including the safety rule made executable |
| `AGENTS.md` | The design rule, for anyone - human or agent - changing this repo |

## Relationship to a personal dotfiles repo

This is not a fork or a subset of one. It is a separate, smaller thing built on
a different foundation: a personal Mac config typically uses `nix-darwin`, which
configures the *system* - the machine name, macOS defaults, sudo, and Homebrew
along with them. Almost all of that is exactly what must not happen here, so it
is not present: there is no `nix-darwin` input, and the only `sudo` in this repo
is the one line that creates Homebrew's prefix. A *rebuild* still runs none. The
one prompt a rebuild can produce is Homebrew's, when a cask has to replace an
application you do not own - see "What this touches" above.

Homebrew is where the two come closest, and it is worth being exact about how.
The personal configuration installs Homebrew through
[nix-homebrew](https://github.com/zhaofengli/nix-homebrew), which ships as a
`nix-darwin` module. This repo reaches the same outcome without it: the same
pinned `Homebrew/brew` source, the same patched store copy, the same generated
`bin/brew`, the same one-time privileged prefix setup - rewritten as a flake
input, a Home Manager activation step and a shell script, because standalone
Home Manager has none of the options that module writes.

Two deliberate differences remain. nix-homebrew can be told to migrate an
existing Homebrew by deleting its repository; that option is not ported, and an
existing Homebrew is always a refusal here. And where the personal configuration
sets a cleanup mode that uninstalls anything not on its list, this one never
does - here Homebrew is a general-purpose package manager with software on it
that nothing in this repo put there.

## License

MIT No Attribution - see [LICENSE](LICENSE).
