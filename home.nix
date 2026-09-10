{ config, lib, pkgs, user, homeDirectory, ... }:

let
  # Where this repository lives. bootstrap.sh points ~/.dotfiles at it, and the
  # out-of-store symlinks below resolve through that name rather than through
  # wherever the clone happens to sit.
  dotfiles = "${config.home.homeDirectory}/.dotfiles";

  # npm's global prefix. The Nix node's own prefix is a read-only store path, so
  # `npm install -g` needs somewhere writable, and that somewhere has to be
  # inside $HOME: /usr/local is not this configuration's to write.
  npmPrefix = "${config.home.homeDirectory}/.npm-global";

  # === Homebrew ==============================================================
  #
  # These two lists are the Homebrew equivalent of home.packages: edit one, run
  # ./rebuild.sh, and Homebrew converges on it. Everything below them is
  # plumbing.
  #
  # Node is deliberately absent. A Homebrew node puts its global npm prefix in
  # /opt/homebrew, outside the home directory; the nixpkgs node above is
  # pointed at ~/.npm-global instead, which is where this configuration is
  # willing to write.
  brews = [ "herdr" "gh" ];
  casks = [ "wezterm" "claude-code" "ghostty" ];

  # Where the generated Brewfile lands, relative to the home directory.
  #
  # Deliberately not ~/.config/homebrew/Brewfile, which is one of the paths
  # `brew bundle --global` reads: `--global` is also the mode in which
  # $HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP turns on an unprompted cleanup, and
  # a cleanup driven by this file would uninstall everything the user installed
  # by hand. Keeping the file off the global search path means no Homebrew
  # command can be pointed at it by accident.
  brewfileTarget = ".config/dotfiles/Brewfile";

  brewfile = ''
    # Generated from home.nix by dotfiles-work. Editing this file has no effect:
    # it is a symlink into the Nix store and every rebuild replaces it. Change
    # the `brews` and `casks` lists in home.nix instead.
    #
    # Applying this file only installs and upgrades what it lists. Nothing here
    # uninstalls anything, so software installed by hand for unrelated reasons
    # is left exactly as it is.
    ${lib.concatMapStringsSep "\n" (b: ''brew "${b}"'') brews}
    ${lib.concatMapStringsSep "\n" (c: ''cask "${c}"'') casks}
  '';

  # The Homebrew step, as a script rather than inline activation text, so that
  # its behaviour can be executed and asserted on directly - a missing `brew`
  # in particular. tests/homebrew.test.sh runs this very file.
  brewBundle = pkgs.writeShellScript "dotfiles-work-brew-bundle" ''
    set -eu

    brewfile="$HOME/${brewfileTarget}"

    # Homebrew belongs to the user, not to this repository. It is installed by
    # hand, and nothing here installs it, upgrades its own installation or
    # removes it - this script only asks an existing Homebrew to install what
    # the Brewfile lists. The two candidate prefixes below are the only literal
    # Homebrew paths in this file, deliberately: tests/safety.test.sh asserts
    # that the built artifact contains those two and nothing else, and a prefix
    # written out in prose would be indistinguishable from one being used.
    #
    # PATH is not consulted, because it cannot be: Home Manager's activation
    # script replaces PATH with a fixed list of Nix store paths before running
    # this, so the user's shell PATH is not visible here at all. What is
    # visible is the rest of their environment, and HOMEBREW_PREFIX is
    # Homebrew's own answer to "where am I" - every shell set up by
    # `brew shellenv` exports it. So it is taken as authoritative when it is
    # set, including when there is no brew inside it: a machine that has been
    # told where Homebrew is and does not have it there is a machine without a
    # usable Homebrew, and saying so is better than quietly using a different
    # one. Otherwise the two prefixes macOS Homebrew supports are tried, Apple
    # silicon first.
    brew=""
    if [ -n "''${HOMEBREW_PREFIX:-}" ]; then
      # Quoted, not word-split: this one comes from the environment.
      searched="$HOMEBREW_PREFIX/bin/brew"
      if [ -x "$searched" ]; then
        brew="$searched"
      fi
    else
      searched="/opt/homebrew/bin/brew /usr/local/bin/brew"
      for candidate in $searched; do
        if [ -x "$candidate" ]; then
          brew="$candidate"
          break
        fi
      done
    fi

    if [ -z "$brew" ]; then
      echo "dotfiles-work: no Homebrew at $searched, so its part of this" >&2
      cat >&2 <<'MISSING'
    configuration cannot be applied.

    This configuration drives Homebrew; it deliberately does not install it.
    Homebrew's installer needs your password and writes outside your home
    directory, so running it is your decision to make, not this repository's -
    and on a Mac you do not administer it may not be yours to make at all.

    Install it yourself from https://brew.sh and run ./rebuild.sh again. If you
    would rather not have Homebrew, empty the `brews` and `casks` lists in
    home.nix: this step then drops out of the rebuild entirely and everything
    else works unchanged.
    MISSING
      exit 1
    fi

    if [ ! -e "$brewfile" ]; then
      echo "dotfiles-work: no Brewfile at $brewfile - the switch that writes it did not run" >&2
      exit 1
    fi

    # `install` and nothing else. There is deliberately no `cleanup`, no
    # `--cleanup`, no `--force-cleanup`, no `--zap` and no `--global`: on this
    # machine Homebrew is the user's own general-purpose package manager, and a
    # declarative cleanup would uninstall everything they installed for reasons
    # this repository knows nothing about.
    #
    # --force is `brew install --force/--overwrite`, which lets a cask claim an
    # app that is already sitting in /Applications instead of failing on it. It
    # does not remove or prune anything.
    #
    # HOMEBREW_NO_AUTO_UPDATE is unset rather than set to 0, because Homebrew
    # reads it as a flag: any value at all, "0" included, turns auto-update
    # off. Unsetting it is what leaves auto-update on.
    unset HOMEBREW_NO_AUTO_UPDATE

    exec "$brew" bundle install --file "$brewfile" --force
  '';
in

{
  home.username = user;

  # Not "/Users/${user}" unconditionally: a managed Mac can put an account's
  # home somewhere else entirely, and building this configuration against the
  # wrong path would have it manage a directory that is not the user's. The
  # override lives in flake.nix; rebuild.sh checks $HOME against it before
  # building, and Home Manager's own activation refuses to run if they differ.
  home.homeDirectory = if homeDirectory != null then homeDirectory else "/Users/${user}";

  home.stateVersion = "26.05";

  # Nix's half of what gets installed. Homebrew's half is the `brews` and
  # `casks` lists above, and nothing appears in both: two installations of the
  # same tool would put two copies of it on PATH, and which one wins would come
  # down to the order of a PATH the user did not write. gh, claude-code, wezterm
  # and ghostty live in Homebrew now; tests/homebrew.test.sh fails if one of
  # them reappears here.
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    # Node from nixpkgs, pinned by flake.lock. Homebrew's node would put its
    # global npm prefix in /opt/homebrew; this one is pointed at ~/.npm-global.
    nodejs_26
    # the font everything renders in
    nerd-fonts.hack
  ];

  fonts.fontconfig.enable = true;

  # How a GUI app from *nixpkgs* would be installed: symlinked into
  # ~/Applications/Home Manager Apps, not copied.
  #
  # There is no such app in home.packages today - the terminals come from
  # Homebrew casks, which put them in /Applications where Spotlight indexes
  # them like any other app. These two lines stay because the choice they
  # encode is not the safe default. From stateVersion 25.11 on, Home Manager's
  # Darwin default is `copyApps`, which rsyncs the bundles - but that needs the
  # macOS "App Management" permission for the terminal, and on failure it calls
  # `tccutil reset` and aborts the whole activation. On a machine whose privacy
  # settings someone else administers that permission may simply not be
  # grantable, and losing an entire switch - shell, editor, git - over one app
  # is the wrong trade. Symlinks need no permission at all.
  targets.darwin.copyApps.enable = false;
  targets.darwin.linkApps.enable = true;

  # The Brewfile, and the step that applies it.
  #
  # `brew bundle install` runs on every switch, so editing the lists above and
  # running ./rebuild.sh is all there is to it - the same loop as home.packages.
  # It is the last thing activation does: writeBoundary is the point at which
  # Home Manager has finished writing the home directory, which is where the
  # Brewfile the script reads comes from.
  #
  # This is where this repository stops being contained by the home directory.
  # Homebrew installs into /opt/homebrew and casks into /Applications, and this
  # step asks it to. README.md says so in the same words; AGENTS.md records what
  # the design rule now is, and tests/safety.test.sh asserts the part of it that
  # still holds.
  home.file."${brewfileTarget}".text = brewfile;

  # Guarded, so that emptying both lists is a real way to opt out and not just a
  # way to ask Homebrew for nothing. With no formulae and no casks there is
  # nothing outside the home directory left to do, and a Mac where Homebrew
  # cannot be installed at all should not fail its rebuild over a step with no
  # work in it - which is what the missing-Homebrew message tells the user, so
  # it had better be true.
  home.activation.homebrewBundle = lib.mkIf (brews != [ ] || casks != [ ])
    (lib.hm.dag.entryAfter [ "writeBoundary" ] "run ${brewBundle}");

  home.sessionVariables.EDITOR = "nvim";
  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;

  home.sessionPath = [ "${npmPrefix}/bin" ];

  # Puts the `home-manager` CLI - `generations`, `news`, `packages` - on PATH at
  # the revision flake.lock pins. The switch itself does not need it:
  # rebuild.sh runs `nix run ~/.dotfiles#home-manager`, which works on a machine
  # that has never activated anything.
  programs.home-manager.enable = true;

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = lib.mkMerge [
      (lib.mkOrder 1000 ''
        bindkey '^f' autosuggest-accept
      '')

      # The untracked seam, at order 1500 (mkAfter) so it really is the last
      # thing .zshrc runs. Home Manager emits the shell aliases at 1150 and the
      # syntax highlighting at 1200, so the default order 1000 would put this
      # *before* them and quietly cost ~/.zshrc.local the ability to override
      # anything this file sets.
      #
      # Everything specific to one machine or one employer belongs in that
      # file: proxy variables, an internal registry, and NODE_EXTRA_CA_CERTS
      # when the network intercepts TLS. It is never committed, and an absent
      # file is a normal state. See README.md.
      (lib.mkOrder 1500 ''
        if [[ -f ~/.zshrc.local ]]; then source ~/.zshrc.local; fi
      '')
    ];
    shellAliases = {
      ".." = "cd ..";
      "add" = "git add .";
      "push" = "git push";
      "pull" = "git pull";
      "m" = "git switch main";
    };
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  programs.git = {
    enable = true;
    # No name or email here on purpose: an identity in this tracked file would
    # follow every clone and fork of this public repo, and on a managed machine
    # the identity is the employer's business, not this repository's.
    #
    # Two includes, and the order matters - later wins in git:
    #   ~/.gitconfig.local   unconditional, the default identity
    #   ~/.gitconfig.work    applied only inside ~/work, via includeIf
    # so a work identity can be scoped to the directory work repositories live
    # in instead of stamping every commit on the machine. Both files are
    # untracked, and both are optional: git ignores an include whose file does
    # not exist.
    includes = [
      { path = "~/.gitconfig.local"; }
      {
        path = "~/.gitconfig.work";
        condition = "gitdir:~/work/";
      }
    ];
  };

  # Edit-in-place: the real files stay in this repo and ~/.config points at
  # them. Neovim's plugin manager writes lazy-lock.json back into its config
  # directory, which a read-only /nix/store copy could not accept.
  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
}
