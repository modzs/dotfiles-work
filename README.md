# dotfiles-work

A small, rarely-changed dotfiles configuration for **a Mac you do not administer**.

It sets up a shell, an editor, a terminal and a handful of command-line tools
inside your home directory - and nothing else. It is deliberately separate from,
and much smaller than, a personal dotfiles repo, because a work Mac is a machine
you cannot easily repair and are not free to reconfigure.

## What this touches, and what it does not

This is the whole point of the repository, so it comes first.

**It writes inside your home directory. That is all it writes.**

| It does | It does not |
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

The one thing that lives outside your home directory is Nix itself, in `/nix`.
Installing it is the single `sudo` this repo ever needs, and after that the
store, your profile generations and everything else Nix does for you belong to
your account.

> **Check with your employer before installing anything.** "It only touches my
> home directory" is a technical statement about this configuration, not
> permission to install software on a machine your employer owns.

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

```sh
git clone https://github.com/modzs/dotfiles-work.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

`bootstrap.sh` installs Nix, points `~/.dotfiles` at this clone, offers to set
the account and home directory this configuration is built for - **defaulting to
this machine's real values, so pressing Enter is always safe** - seeds the two
untracked local files described below, and runs the first switch.

Open a new terminal afterwards.

From then on, every change is:

```sh
./rebuild.sh
```

No `sudo`. If something asks you for a password, it is not this repo.

### Look before you leap

To see what would be built without changing anything:

```sh
nix flake check --all-systems   # evaluate both architectures
nix build .#default             # build this Mac's configuration, do not activate
./tests/run.sh                  # run the behaviour tests
```

`nix build` is not `switch`. It produces the configuration in the Nix store and
touches nothing in your home directory.

## Making it yours

There is exactly one place to edit, at the top of `flake.nix`:

```nix
user = "john";
homeDirectory = null;
```

`user` is the account this is built for. `homeDirectory` is normally `null`,
which means `/Users/<user>`; set it to an explicit path if your account's home
directory is somewhere else, which does happen on a managed Mac. `bootstrap.sh`
writes both for you.

You do **not** set the architecture. `flake.nix` exposes a configuration for
each of `aarch64-darwin` and `x86_64-darwin`, and the scripts pick the one that
matches the Mac they are running on.

To add a package, add it to `home.packages` in `home.nix` and run `./rebuild.sh`.

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

### `~/.gitconfig.local`

Your default git identity:

```ini
[user]
    name = Your Name
    email = you@example.com
```

The tracked configuration sets no name or email at all - an identity committed
here would follow every clone of a public repo, and on a work machine it is not
this repository's business.

### `~/.gitconfig.work`

The same keys, but applied **only inside `~/work`**, through git's `includeIf`:

```ini
[user]
    email = you@your-employer.example
```

So a work identity applies to work repositories and nothing else. Keep work
clones under `~/work` and it happens automatically. Both files are optional; git
ignores an include whose file does not exist.

If git ever cannot resolve a name or an email, `bootstrap.sh` and `rebuild.sh`
say so and print the exact command to fix it.

One caveat, because it bites people: this configuration writes
`~/.config/git/config`, and git reads `~/.gitconfig` **after** that. If your Mac
already had a `~/.gitconfig` with an identity in it, that identity still wins.
`git config --show-origin --get user.email` names the file that won.

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
immediately without a rebuild. That is also why neovim's plugin manager can
write `lazy-lock.json` back.

### Intel Macs

Fully supported, and CI evaluates the Intel configuration on every change.
Note that nixpkgs 26.05 - the release this repo pins - is the **last** one to
support `x86_64-darwin`. An Intel Mac can stay on this pin indefinitely, which
suits a configuration meant to be left alone; a future nixpkgs bump will be an
Apple-silicon-only move.

### Rolling back and removing

```sh
nix run ~/.dotfiles#home-manager -- generations   # list what has been activated
nix run ~/.dotfiles#home-manager -- uninstall     # remove it all again
```

`uninstall` puts your home directory back and leaves Nix itself in place.

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
