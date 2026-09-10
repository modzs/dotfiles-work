# dotfiles-work

A small, rarely-changed dotfiles configuration for **a Mac you do not administer**.

It sets up a shell, an editor, a terminal and a handful of command-line tools
inside your home directory - and nothing else. It is deliberately separate from,
and much smaller than, a personal dotfiles repo, because a work Mac is a machine
you cannot easily repair and are not free to reconfigure.

## What this touches, and what it does not

This is the whole point of the repository, so it comes first.

There are two separate things here, and the honest answer is different for
each: **this configuration**, which is everything in this repository, and
**installing Nix**, which `bootstrap.sh` hands to a third-party installer once.

### This configuration writes inside your home directory. That is all it writes.

| This configuration does | This configuration does not |
| --- | --- |
| Install command-line tools and two terminal apps for your account | Install a system-wide package manager, or remove software someone else installed |
| Write config files under `~/.config`, `~/.zshrc`, `~/Applications` | Write to `/etc`, `/Library`, `/usr`, `/opt`, or `/Applications` |
| Manage your own shell, editor, git and terminal settings | Change the computer's name, network settings, or macOS system settings |
| Ask for your password **once**, to install Nix | Ask for your password ever again |

Concretely, this configuration has no way to rename the machine, edit
`/etc/sudoers` or `sshd_config`, install a system package manager, write
system-domain macOS defaults, or manage other user accounts - because it is a
[standalone Home Manager](https://nix-community.github.io/home-manager/)
configuration and those settings do not exist in it. `tests/safety.test.sh`
asserts that mechanically, so a future change cannot quietly reintroduce them.

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

So "it only touches my home directory" is true of the configuration and not of
installing Nix. After the install, the store, your profile generations and
everything else Nix does for you belong to your account, and nothing else on
the machine is touched again.

That last row is the one to remember on a managed Mac: the `/etc/zshrc` block
is what makes any of this reachable from a shell, and it is a system file this
repository will never write to. `bootstrap.sh` and `rebuild.sh` both check
whether a fresh login shell can actually find what is installed, and say so
plainly when it cannot - they can tell you where to look, and they cannot fix
it for you. If management software has dropped that block, the repair that is
yours to make is a `PATH` line in `~/.zshrc.local`, below.

> **Check with your employer before installing anything.** The paragraphs above
> are technical statements about what runs, not permission to install software
> on a machine your employer owns.

## What you get

- **zsh** with autosuggestions, syntax highlighting and a
  [starship](https://starship.rs) prompt
- **neovim**, configured, with the plugin set in `home/.config/nvim`
- **git**, wired to include untracked local files for your identity
- **wezterm** and **ghostty**, two terminal emulators
- `ripgrep`, `fd`, `fzf`, `jq`, `lazygit`, `gh`, `claude-code`, Node, and the
  Hack Nerd Font

Every version is pinned by `flake.lock`. Nothing updates on its own: this is
meant to be installed once and left alone, and an update is something you do
deliberately.

## Prerequisites

- macOS on Apple silicon **or** Intel. Both are first-class here - the
  architecture is detected, not configured.
- The ability to install Nix, which needs your password once. If your employer's
  policy does not allow that, this repo cannot be used.

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

### The GUI apps are symlinked, and Spotlight will not find them

WezTerm and Ghostty are installed into `~/Applications/Home Manager Apps` as
symlinks pointing into the Nix store. Verified: macOS resolves a real
executable in both bundles through those symlinks, so opening one in Finder
launches it, and `tests/packages.test.sh` re-checks that on every run.

What is **not** promised is Spotlight. Home Manager's own documentation
describes the copying mode - not this one - as the one that "works with
Spotlight", so assume ⌘-Space will not find these two and that `open -a WezTerm`,
which needs the same Launch Services registration, may not either. The
dependable ways to start them are:

```sh
open ~/Applications/Home\ Manager\ Apps/WezTerm.app   # by path, always works
wezterm                                              # both are also on PATH
ghostty
```

Opening one from Finder once, or dragging it to the Dock, is usually enough to
make it behave like any other app afterwards.

Home Manager can instead *copy* the bundles, which Spotlight does index - but
copying requires the macOS **App Management** permission for your terminal, and
when it cannot get that permission it aborts the entire activation. On a machine
whose privacy settings someone else administers, that permission may not be
grantable at all, and losing your whole shell setup over two terminal emulators
is a bad trade. If your machine does allow it, flip the two lines in `home.nix`:

```nix
targets.darwin.copyApps.enable = true;
targets.darwin.linkApps.enable = false;
```

### Globally installed npm packages

`npm install -g` writes into `~/.npm-global`, which is on your `PATH`. Node
itself comes from nixpkgs and lives in the read-only Nix store, so npm needs a
writable prefix somewhere - and the only place this configuration will put one
is inside your home directory.

### `herdr` is not installed

`herdr` is not in nixpkgs, so this configuration cannot install it. Install it
by hand, however your setup allows, and it will work alongside everything here.
Nothing in this repo depends on it.

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
| `home.nix` | Everything that gets installed and configured |
| `home/.config/` | Editor and terminal config, symlinked live into `~/.config` |
| `bootstrap.sh` | One-time setup: Nix, settings, local files, first switch |
| `rebuild.sh` | Every later change |
| `lib/` | The shared shell functions both scripts use |
| `tests/` | Behaviour tests, including the safety rule made executable |
| `AGENTS.md` | The design rule, for anyone - human or agent - changing this repo |

## Relationship to a personal dotfiles repo

This is not a fork or a subset of one. It is a separate, smaller thing built on
a different foundation: a personal Mac config typically uses `nix-darwin`, which
configures the *system* - the machine name, macOS defaults, Homebrew, sudo. All
of that is exactly what must not happen here, so none of it is present. The
editor and shell configuration is shared in spirit; the machinery underneath is
not.

## License

MIT No Attribution - see [LICENSE](LICENSE).
