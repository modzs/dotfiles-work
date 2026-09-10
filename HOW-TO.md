# How to

Task-shaped answers for the things you will actually want to do. For what this
repository is and what it deliberately does not touch, read
[README.md](README.md) first.

Everything this repository runs runs as you, never as root, and neither
`./bootstrap.sh` nor `./rebuild.sh` asks you for a password in its own code.
Two prompts can still appear, and both come from something this repo runs rather
than from this repo:

- `./bootstrap.sh` step 1 installs Nix, and the Determinate installer it runs
  asks for a password. That is the single sudo in the whole setup, and the
  script says so as it happens.
- a rebuild can prompt if a cask on the list has to replace an application you
  do not own - one your employer's management software deployed. Homebrew cannot
  remove that as you, so it falls back to taking ownership with `sudo`. See
  README.md, which is exact about when this happens.

A password prompt from anywhere else means something is wrong - stop and check
what you are running. Homebrew is the one thing this file asks you to install
beforehand, and its installer asks for a password too - again its own, which is
exactly why installing it is your decision rather than a step this repo takes
for you.

---

## Set it up on a new Mac

### What you get, and what you do not

Read this first if you have ever set up a Mac with a personal dotfiles repo,
because the shape is different and the difference looks like failure.

**You get** everything in README's [What you get](README.md#what-you-get) - a
configured shell and editor, git, two terminal emulators and a handful of
command-line tools. Most of it comes from nixpkgs, pinned by `flake.lock`; a
short list of formulae and casks comes from Homebrew instead.

**You do not get a Homebrew.** This repository never installs a system package
manager and never will - that is the whole reason it is separate from a
personal dotfiles repo. It drives the Homebrew *you* installed, and refuses to
finish the switch when there is none.

Two things follow from that, and both are normal:

| You look here | You find | Because |
| --- | --- | --- |
| `~/Applications/Home Manager Apps` | nothing | no app on the Nix side today - the terminals are casks, so they land in `/Applications` |
| the shell you just ran `bootstrap.sh` in | nothing | Nix only reaches shells started afterwards |

`ls ~/.nix-profile/bin` and `brew list` are the two commands that show you what
really got installed. `bootstrap.sh` prints the first when it finishes.

### The setup

**First, install Homebrew** - this repo does not, and will not. Follow
[brew.sh](https://brew.sh). Its installer asks for your password and writes
outside your home directory, which is exactly why the decision is yours and not
this repository's. This step is not optional: if you are not free to make that
decision on this Mac, this repo is not usable as it stands. See "There is no way
to turn the Homebrew part off" below.

Check that it worked, in a new terminal:

```sh
brew --version
```

Then:

```sh
git clone https://github.com/modzs/dotfiles-work.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

**Then open a new terminal, before you run anything else.** The Nix installer
only adds `nix` to the `PATH` of shells started after it ran, so the shell you
bootstrapped from has neither `nix` nor any of the new tools - and `./rebuild.sh`
will refuse to run there. This catches nearly everyone once.

`bootstrap.sh` is safe to run twice. Every step checks the machine's current
state first and skips what is already done.

---

## Apply a change

```sh
./rebuild.sh
```

That is the whole loop: edit `home.nix`, run `./rebuild.sh`, open a new shell if
you changed something the shell reads at startup.

It applies both halves. Home Manager writes your home directory, then the last
step hands the generated Brewfile to `brew bundle install`, so a formula or cask
you added is installed by the same command. That step only ever installs what is
missing - it never uninstalls, so anything you installed with `brew` by hand
stays where it is. A name on the lists that is already installed is skipped
outright, so it stays at the version it is on. The one thing that can still move
is a *dependency*: when Homebrew installs something new off the lists, it may
upgrade an outdated library that install needs. Nothing here asks it to, and
nothing on the lists is upgraded just for being there.

The Homebrew step runs on every rebuild, not only when the lists change, so a
rebuild does need the network. Even when everything on the lists is already
installed it still asks Homebrew, and asking is not free: unless you have
exported `HOMEBREW_NO_AUTO_UPDATE` yourself, Homebrew may update its own
checkout and taps before answering, the same as it would on any `brew install`.
This repo neither sets that variable nor clears it, and it never runs
`brew update` itself.

---

## See what would happen, without changing anything

```sh
nix flake check --all-systems   # does it evaluate, for both architectures?
nix build .#default             # does it build? nothing is activated
./tests/run.sh                  # do the behaviour tests still pass?
```

`nix build` writes the result into the Nix store and touches nothing in your
home directory. `switch` is the only thing that changes your home directory, and
only `./bootstrap.sh` and `./rebuild.sh` run it.

---

## Add or remove a tool

There are two lists, and which one you use decides what you get.

**Nix** (`home.packages`) gives you a version pinned by `flake.lock`: the same
everywhere, forever, until you deliberately update. Use it for command-line
tools. **Homebrew** (`brews` and `casks`) gives you whatever Homebrew resolves
on the day you rebuild, and puts applications in `/Applications` where Spotlight
finds them. Use it for GUI applications, and for anything not in nixpkgs.

Never put the same tool in both. Two copies on your `PATH` are resolved by an
ordering you did not choose, and `tests/homebrew.test.sh` fails if it happens.

### From Nix

```nix
  home.packages = with pkgs; [
    ripgrep
    fd
    your-new-tool
  ];
```

Then `./rebuild.sh`.

Search for the right attribute name at
[search.nixos.org/packages](https://search.nixos.org/packages). Two things to
check before you add one:

1. **Does it exist for macOS?** Some packages are Linux-only. `ghostty` is:
   the working attribute on macOS is `ghostty-bin`.
2. **Does it exist for both architectures?** `tests/packages.test.sh` will tell
   you - it evaluates every declared package for `aarch64-darwin` *and*
   `x86_64-darwin` and fails naming any that is missing from either.

### From Homebrew

Edit the two lists near the top of `home.nix`:

```nix
  brews = [ "herdr" "gh" ];
  casks = [ "wezterm" "claude-code" "ghostty" ];
```

Then `./rebuild.sh`. Find names with `brew search <thing>`.

**Removing a name from these lists does not uninstall anything.** It only stops
the rebuild from installing it. That is deliberate - see "What this touches" in
[README.md](README.md) - and it means uninstalling is a thing you do yourself:

```sh
brew uninstall <formula>
brew uninstall --cask <cask>
```

### There is no way to turn the Homebrew part off

This configuration requires Homebrew. Emptying both lists:

```nix
  brews = [ ];
  casks = [ ];
```

does not remove the step from the rebuild. It still runs, still needs a `brew`
to talk to, and asks it to install nothing - so on a Mac without Homebrew the
rebuild still stops with the message below. Nothing already installed is
removed either; emptying the lists never uninstalls anything.

---

## Set or change your git identity

Nothing tracked in this repo carries a name or an email. Write yours to the
untracked file the generated git config includes:

```sh
git config --file ~/.gitconfig.local user.name "Your Name"
git config --file ~/.gitconfig.local user.email "you@example.com"
```

For an identity that should apply only to work repositories, put it in
`~/.gitconfig.work` instead and keep those clones under `~/work`:

```sh
git config --file ~/.gitconfig.work user.email "you@your-employer.example"
```

Check what git actually resolves, and where from:

```sh
git config --show-origin --get user.email
```

`rebuild.sh` warns you if git would have to invent an identity, and prints the
command that fixes it.

**If your identity is not the one you just set**, see the
`~/.gitconfig-takes-precedence` note in [README.md](README.md#the-untracked-local-files)
for an explanation of how git searches your configuration files. Move the keys
out of `~/.gitconfig` into `~/.gitconfig.local` and the seam works as described.

---

## Add something employer-specific

It goes in `~/.zshrc.local`, which is sourced last by your `.zshrc` and is never
committed. `bootstrap.sh` creates it with commented examples.

A corporate network that inspects TLS is the common case: without a trusted CA,
every HTTPS request from Node fails with a certificate error.

```sh
echo 'export NODE_EXTRA_CA_CERTS="$HOME/certs/your-ca.pem"' >>~/.zshrc.local
exec zsh
```

Nothing employer-specific belongs in a tracked file. This repository is public.

---

## Move to a different Mac, or a different account

Open `flake.nix` and change the two lines at the top - or let `bootstrap.sh` do
it, which offers this machine's real values as the defaults:

```nix
user = "john";
homeDirectory = null;
```

You never set the architecture. Both `aarch64-darwin` and `x86_64-darwin`
configurations exist, and the scripts pick the one matching the Mac they run on.

If your account's home directory is not `/Users/<user>` - which happens on
managed Macs - set `homeDirectory` to the real path. `rebuild.sh` refuses to
build a configuration whose home directory is not yours, and says exactly what
to change.

---

## Undo a change

List what has been activated, then activate an older generation:

```sh
nix run ~/.dotfiles#home-manager -- generations
```

Each line names a store path. Run its `activate` script to go back:

```sh
/nix/store/...-home-manager-generation/activate
```

---

## Remove it all

```sh
nix run ~/.dotfiles#home-manager -- uninstall
```

That restores your home directory. Two things it does not undo, both on purpose:

- **the Homebrew formulae and casks stay installed.** This repo never uninstalls
  anything through Homebrew, and that does not change just because you are
  removing the repo. Use `brew uninstall` on whatever you no longer want;
- **Nix itself stays installed.** Removing Nix is a separate, system-level
  operation, and so is removing Homebrew.

---

## Update the pinned versions

This configuration is meant to be left alone, so nothing updates on its own.
When you do want newer packages:

```sh
nix flake update          # move to the current commit of the tracked channels
nix build .#default       # does it still build?
./tests/run.sh            # do the tests still pass?
./rebuild.sh              # apply it
```

This pins only the Nix half. Homebrew's formulae and casks are not pinned by
anything here: a rebuild installs whichever version Homebrew is offering at the
time and then leaves it alone, so what you end up with depends on when you first
installed it. Upgrading them is a separate, deliberate act:

```sh
brew upgrade <formula>
brew upgrade --cask <cask>
```

That is the cost of having them come from Homebrew, and it is why the tools
worth keeping reproducible are on the Nix side.

Commit the resulting `flake.lock` from a machine you are willing to commit from.

Note that nixpkgs 26.05, the release pinned here, is the last one to support
Intel Macs. Staying on this pin is a perfectly good answer for a configuration
whose job is to be boring.

---

## Edit the neovim or wezterm configuration

`~/.config/nvim` and `~/.config/wezterm` are symlinks into this repository, not
copies. Edit the files under `home/.config/` (or through the symlink, which is
the same file) and the change takes effect immediately - no rebuild.

That is also why neovim's plugin manager can write `lazy-lock.json` back: a Nix
store copy would be read-only.

---

## Troubleshooting

**`HOME is "/Users/a", expected "/Users/b"`** - the configuration is built for a
different home directory than the one you are in. Fix the `homeDirectory` line in
`flake.nix`, or run `./bootstrap.sh`.

**`Existing file '/Users/you/.zshrc' is in the way`** - the first switch found a
file it wants to own. `bootstrap.sh` passes `-b backup`, which renames it to
`.zshrc.backup` instead of failing. If you hit this from `rebuild.sh`, move the
file aside yourself and run it again.

**`nix: command not found` right after bootstrapping** - open a new terminal.
If a new terminal still cannot find it, the Nix block is missing from
`/etc/zshrc`; see [README.md](README.md#what-this-touches-and-what-it-does-not)
for what to do about that on a Mac you do not administer.

**`dotfiles-work: no Homebrew at ...`** - the rebuild got all the way to its
last step and found no `brew` to talk to. Everything Nix installs is already in
place; only the formulae and casks are missing. Install Homebrew from
[brew.sh](https://brew.sh) and run `./rebuild.sh` again - this configuration
requires it, and emptying the lists in `home.nix` is not a way around it. If
Homebrew *is* installed, check `HOMEBREW_PREFIX`: the step trusts that variable
when the environment sets it, and a stale value points it at the wrong place.

**A rebuild succeeds but `gh` or `herdr` is not found** - Homebrew installed
them, but your shell cannot see Homebrew's `bin` directory. This repo finds
`brew` by its prefix rather than through `PATH`, so the rebuild does not depend
on the thing your shell is missing. Add Homebrew's own line to `~/.zprofile`:

```sh
eval "$(/opt/homebrew/bin/brew shellenv)"
```

**A package will not build** - check that it exists for macOS and for your
architecture; see "Add or remove a tool" above.

**The terminal apps are not in Spotlight** - they should be; they are Homebrew
casks in `/Applications` now. If they are not, check that the cask actually
installed: `brew list --cask`.
