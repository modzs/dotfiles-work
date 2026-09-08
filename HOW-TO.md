# How to

Task-shaped answers for the things you will actually want to do. For what this
repository is and what it deliberately does not touch, read
[README.md](README.md) first.

Everything here runs as you, never as root. If a step in this file ever asks for
a password, something is wrong - stop and check what you are running.

---

## Set it up on a new Mac

```sh
git clone https://github.com/modzs/dotfiles-work.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

Then open a new terminal. The Nix installer only adds `nix` to the `PATH` of
shells started after it ran, so the shell you bootstrapped from will not have
the new tools.

`bootstrap.sh` is safe to run twice. Every step checks the machine's current
state first and skips what is already done.

---

## Apply a change

```sh
./rebuild.sh
```

That is the whole loop: edit `home.nix`, run `./rebuild.sh`, open a new shell if
you changed something the shell reads at startup.

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

Edit the `home.packages` list in `home.nix`:

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

**If your identity is not the one you just set**, you probably already have a
`~/.gitconfig`. This configuration writes `~/.config/git/config`, and git reads
`~/.gitconfig` *after* that - so a file the machine already had wins over both
`~/.gitconfig.local` and `~/.gitconfig.work`. The command above names the file
that won. Move the keys out of `~/.gitconfig` into `~/.gitconfig.local` and the
seam works as described.

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

That restores your home directory. Nix itself stays installed; removing Nix is a
separate, system-level operation and is deliberately not something this repo
does.

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

**A package will not build** - check that it exists for macOS and for your
architecture; see "Add or remove a tool" above.

**The terminal apps are not in Spotlight** - expected. See the GUI apps section
in [README.md](README.md).
