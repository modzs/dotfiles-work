# dotfiles-work

A small, rarely-changed dotfiles configuration for **a Mac you do not administer**.

It sets up a shell, an editor, a terminal and a handful of command-line tools:
most of it inside your home directory, and one part - a list of Homebrew
formulae and casks - through a Homebrew you install yourself. It is deliberately
separate from, and much smaller than, a personal dotfiles repo, because a work
Mac is a machine you cannot easily repair and are not free to reconfigure. The
next section is exact about where the line falls.

## What this touches, and what it does not

This is the whole point of the repository, so it comes first, and it is written
to be read by someone deciding whether it may run on a machine they are
responsible for.

There are two separate things here, and the honest answer is different for
each: **this configuration**, which is everything in this repository, and
**installing Nix**, which `bootstrap.sh` hands to a third-party installer once.

**Most of what this configuration does is confined to your home directory. One
part is not.**

This configuration drives Homebrew. It generates a list of formulae and casks,
and on every rebuild it asks a Homebrew *you already installed* to install what
is on that list. Homebrew installs into its own prefix - `/opt/homebrew` on
Apple silicon, `/usr/local` on Intel - and casks put real applications in
`/Applications`. Both are outside your home directory. That is a deliberate
choice by the owner of this repo, not an accident, and this section says so
rather than claiming a containment that no longer holds.

### What this configuration writes, and the one place it reaches further

| This configuration does | This configuration does not |
| --- | --- |
| Install command-line tools for your account from Nix, inside your home directory | Write to `/etc`, `/Library`, `/usr`, `/private`, or any macOS system domain |
| Ask an existing Homebrew to install a fixed list of formulae and casks | Install, update, or remove Homebrew itself |
| Add to what Homebrew has installed | Uninstall *anything* - see below |
| Write config files under `~/.config`, `~/.zshrc`, `~/Applications` | Change the computer's name, network settings, or macOS system settings |
| Ask for your password **once**, to install Nix | Ask for your password ever again |

Three of those deserve to be spelled out.

**It never uninstalls anything.** Homebrew's "bundle" mechanism can be run in a
mode that uninstalls whatever is not on the list. This configuration does not
run it that way and has no option to. Software installed on this Mac by anyone,
for any reason - a security agent, a VPN client, a managed application - is
never uninstalled, not now and not on any future rebuild. The test suite runs
the step against a stand-in for `brew` and fails if it ever passes a flag that
could uninstall.

There is one thing it *will* replace, and it is worth being exact about. The
step passes `--force`, so a cask is allowed to claim an application already
sitting at the path it installs to. That means an app whose name is on the cask
list in `home.nix` - today WezTerm, Ghostty and Claude Code - is replaced by
Homebrew's copy if it is already in `/Applications`, however it got there.
Nothing whose name is not on that list is touched at all.

**It never installs Homebrew.** Homebrew's own installer needs a password and
writes outside the home directory, so running it is a decision for whoever owns
the machine. If Homebrew is absent, this configuration stops with an explanation
and changes nothing.

**Everything else really is confined.** This is a
[standalone Home Manager](https://nix-community.github.io/home-manager/)
configuration with no `nix-darwin`, which means it has no way to express a
machine name, an `/etc/sudoers` edit, an `sshd_config`, a system-domain macOS
default, or another user account - those settings do not exist in it, so they
cannot be set by accident or by a future change. `tests/safety.test.sh` asserts
that mechanically against the evaluated configuration and the built artifact,
and `tests/homebrew.test.sh` asserts the Homebrew claims above by executing
them.

### Installing Nix is a system-level install, and it does write outside `$HOME`

This is the one step `bootstrap.sh` does not do itself. It runs the
[Determinate Systems installer](https://install.determinate.systems), once, and
that is the single `sudo` in the whole setup. Nothing in this repository can do
any of the following; the installer does, and it is worth knowing before you
show this repo to whoever administers your Mac:

| Path | What it is |
| --- | --- |
| `/nix`, on its own APFS volume | the Nix store: every package installed for your account |
| `/etc/nix/` | the daemon's configuration |
| `/etc/synthetic.conf` | the entry that lets `/nix` exist at the root of the disk |
| `/Library/LaunchDaemons/systems.determinate.*.plist` | the build daemon that runs in the background |
| a block appended to `/etc/zshrc` and `/etc/bashrc` | what puts `nix`, and the tools this configuration installs, on the `PATH` of new shells |

So "it only touches my home directory" is true of the configuration apart from
the Homebrew step above, and it is not true of installing Nix at all. After the
install, the store, your profile generations and everything else Nix does for
you belong to your account, and nothing else on the machine is touched again.

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
> owns.

## What you get

From **Nix**, pinned by `flake.lock`:

- **zsh** with autosuggestions, syntax highlighting and a
  [starship](https://starship.rs) prompt
- **neovim**, configured, with the plugin set in `home/.config/nvim`
- **git**, wired to include untracked local files for your identity
- `ripgrep`, `fd`, `fzf`, `jq`, `lazygit`, Node, and the Hack Nerd Font

From **Homebrew**, whatever it resolves at the time you rebuild:

- `herdr` and `gh`
- **WezTerm**, **Ghostty** and **Claude Code**, as casks

The two halves are declared separately in `home.nix` and nothing appears in
both. The trade between them is real: the Nix half is reproducible - the same
`flake.lock` gives the same versions on any machine, forever - and the Homebrew
half is not, because a Brewfile names a formula and Homebrew decides the
version. What the Homebrew half buys is that its applications land in
`/Applications` like any other Mac application, where Spotlight and Launch
Services find them.

Nothing updates on its own. This is meant to be installed once and left alone,
and an update is something you do deliberately. That holds for both halves: a
rebuild installs whatever on the Homebrew list is missing and leaves what is
already installed at the version it is, so upgrading a formula or a cask stays
something you ask for with `brew`.

## Prerequisites

- macOS on Apple silicon **or** Intel. Both are first-class here - the
  architecture is detected, not configured.
- The ability to install Nix, which needs your password once. If your employer's
  policy does not allow that, this repo cannot be used.
- **Homebrew**, installed by you before you run `./bootstrap.sh`. This repo
  never installs it; see [HOW-TO.md](HOW-TO.md). If you cannot or would rather
  not have Homebrew, empty the `brews` and `casks` lists in `home.nix`: the
  Homebrew step then drops out of the rebuild entirely and the rest works
  unchanged, inside your home directory as before.

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

WezTerm, Ghostty and Claude Code are Homebrew casks, so they install into
`/Applications` exactly like any application you download yourself. Spotlight
indexes them, `open -a WezTerm` works, and they appear in the Dock and in
Launchpad without anything special being done to them.

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

### Homebrew has to be there before the first rebuild

The Homebrew step runs on every switch, and it does not install Homebrew - see
"What this touches" above for why. If Homebrew is missing, the rebuild stops and
tells you so; everything Nix installs has already been written by that point, so
your shell and editor are configured either way.

Homebrew also needs to be on your `PATH` for the tools it installs to be
usable. Its own installer arranges that, normally by adding
`eval "$(/opt/homebrew/bin/brew shellenv)"` to `~/.zprofile`. This repo does not
touch your `PATH` for Homebrew's sake, and it finds `brew` by its prefix rather
than by `PATH`, so a rebuild can succeed on a machine where your shell still
cannot see `gh`. If that happens, the missing piece is that line.

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
| `flake.nix` | The two adjustable settings, and the configuration for both architectures |
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
is not present: there is no `nix-darwin` input, and a rebuild never asks for a
password.

Homebrew is the one thing the two have in common, and even there the mechanism
differs. `nix-darwin` has Homebrew options; standalone Home Manager has none, so
this repo generates a Brewfile and runs `brew bundle install` against it from an
activation step. The personal configuration also sets a cleanup mode that
uninstalls anything not on its list. This one deliberately does not, because
here Homebrew is a general-purpose package manager with software on it that
nothing in this repo put there.

## License

MIT No Attribution - see [LICENSE](LICENSE).
