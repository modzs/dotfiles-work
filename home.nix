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
  # `brew bundle --global` reads. A file sitting there is one any `brew bundle`
  # command run for an unrelated reason would pick up, including a `brew bundle
  # cleanup` the user meant to point at a Brewfile of their own; keeping it off
  # that search path means this generated list is used when this step passes
  # `--file` and at no other time.
  #
  # This is worth having on its own merits, and it is not a safety mechanism.
  # It does not stop an environment-driven cleanup: those variables are not
  # gated on `--global`, and the step neutralizes them itself right before it
  # runs Homebrew. See the comment there.
  brewfileTarget = ".config/dotfiles/Brewfile";

  brewfile = ''
    # Generated from home.nix by dotfiles-work. Editing this file has no effect:
    # it is a symlink into the Nix store and every rebuild replaces it. Change
    # the `brews` and `casks` lists in home.nix instead.
    #
    # Applying this file installs what it lists and leaves what is already
    # installed alone. Nothing here uninstalls anything, so software installed
    # by hand for unrelated reasons is left exactly as it is - with one
    # exception worth knowing: an application already sitting where a cask on
    # this list wants to be is replaced by that cask.
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
    #
    # bootstrap.sh answers the same question before anything is installed, in
    # lib/homebrew-present.sh, so this rule exists twice. The two must agree -
    # a preflight that accepts a Mac this step then refuses is the failure it
    # exists to prevent - and tests/homebrew.test.sh runs both against the same
    # prefixes and fails if their verdicts differ.
    #
    # That first branch is also the only lever that makes the missing-Homebrew
    # failure path above reachable in a test on a machine that *has* Homebrew,
    # which is every CI runner - macos-latest ships it preinstalled.
    # tests/homebrew.test.sh:test_a_missing_homebrew_fails_with_an_explanation
    # points HOMEBREW_PREFIX at an empty directory for exactly that purpose. It
    # has been proposed as a redundant second acceptance path and kept
    # deliberately: dropping it would trade a working guarantee for a tidier
    # line.
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

    Install it yourself from https://brew.sh and run ./rebuild.sh again. This
    configuration requires it: emptying the `brews` and `casks` lists in
    home.nix does not turn this step off, it only leaves it with nothing to
    install.
    MISSING
      exit 1
    fi

    # `install` and nothing else. There is deliberately no `cleanup`, no
    # `--cleanup`, no `--force-cleanup`, no `--zap` and no `--global`: on this
    # machine Homebrew is the user's own general-purpose package manager, and a
    # declarative cleanup would uninstall everything they installed for reasons
    # this repository knows nothing about. Passing no such flag is necessary
    # but not sufficient - see the two variables unset below.
    #
    # --no-upgrade is nix-darwin's `homebrew.onActivation.upgrade = false`,
    # which is the default the personal configuration this mirrors leaves in
    # place: a rebuild installs what is missing and does not touch a formula or
    # cask that is already there. Upgrading stays something the user asks for
    # with `brew` when they mean it, rather than something a rebuild does to
    # five packages behind their back.
    #
    # --force is `brew install --force/--overwrite`, which lets a cask claim an
    # app that is already sitting in /Applications instead of failing on it -
    # so an app whose name is on the cask list above is replaced by that cask.
    # It does not remove or prune anything else.
    #
    # HOMEBREW_NO_AUTO_UPDATE is deliberately not touched, in either direction.
    # nix-darwin's `autoUpdate = true` only declines to *set* the variable; it
    # never clears one the user exported, and clearing it here would silently
    # reverse a deliberate choice - a slow or proxied network is exactly why
    # someone sets it.
    #
    # The two below are a different question, and the only two variables this
    # step touches. Passing no cleanup flag is not enough to keep a cleanup
    # from running, because `brew bundle install` accepts both of these from
    # the environment and they turn on exactly the mass uninstall this
    # repository exists to prevent - every formula and cask not in the
    # Brewfile, an employer's security agent included. Three things about them
    # are worth knowing before touching this:
    #
    #   - they are NOT gated on `--global`, whatever Homebrew's own help text
    #     suggests. In cli/parser.rb the second element of a switch's `env:`
    #     pair is used only to build that sentence; the switch is then set from
    #     the environment unconditionally.
    #   - HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP reaches the cleanup without
    #     needing `--force` at all. Dropping `--force` from the line below
    #     would therefore not fix this, so nobody should try.
    #   - unsetting is the only neutralization that works. The parser asks
    #     whether the value is *present*, not whether it is true, so "0" turns
    #     the switch on just as "1" does - the same trap as
    #     HOMEBREW_NO_AUTO_UPDATE above, for the same reason.
    #
    # Unlike auto-update, these are not a preference of the user's that this
    # step is second-guessing: their only effect here is to make the step do
    # the one thing this repository forbids.
    unset HOMEBREW_BUNDLE_INSTALL_CLEANUP HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP

    exec "$brew" bundle install --file "$brewfile" --no-upgrade --force
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
  # It runs after everything that writes the home directory, which is what the
  # edges below buy. It is not literally last - `setupLaunchAgents` follows it,
  # and under `set -eu` a Homebrew failure skips that step. Nothing is stranded
  # by that: this configuration declares no launchd agents, and the step
  # reconciles the new generation against the old one every time rather than
  # behind a marker, so a skipped run self-heals on the next successful switch.
  # That is exactly the property the three edges below exist to give the steps
  # that do not have it.
  # `writeBoundary` is only a barrier - it writes nothing - so an entry naming
  # it alone is free to be ordered before `linkGeneration`, and `linkGeneration`
  # is the step that puts the Brewfile this script reads into the home
  # directory. Home Manager breaks an unconstrained tie by attribute name, and
  # `homebrewBundle` sorts first, so without that edge the step reads the
  # previous generation's Brewfile - or none at all on a first switch.
  #
  # The other two edges are there because this step can fail on a machine that
  # has no Homebrew, activation runs under `set -eu`, and a failure here must
  # not take anything else down with it. `installPackages` is what makes true
  # the promise README.md, HOW-TO.md and bootstrap.sh all make, that when
  # Homebrew is missing everything Nix installs has already been applied.
  # `onFilesChange` is the one that would not self-heal: it holds the font
  # rsync into ~/Library/Fonts, guarded by a marker file that `linkGeneration`
  # has already placed in $HOME by the time this runs. Fail in between and the
  # next rebuild finds the marker matching, decides nothing changed, and skips
  # the rsync forever - so the font is never installed and the prompt renders
  # tofu until the font derivation itself changes.
  #
  # This is where this repository stops being contained by the home directory.
  # Homebrew installs into /opt/homebrew and casks into /Applications, and this
  # step asks it to. README.md says so in the same words; AGENTS.md records what
  # the design rule now is, and tests/safety.test.sh asserts the part of it that
  # still holds.
  home.file."${brewfileTarget}".text = brewfile;

  # Unconditional. This configuration requires Homebrew, and emptying the lists
  # above is not a way to opt out of it: the step still runs, still needs a
  # `brew` to talk to, and asks it to install nothing.
  home.activation.homebrewBundle =
    lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" "installPackages" "onFilesChange" ]
      "run ${brewBundle}";

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
