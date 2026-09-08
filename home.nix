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

  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    gh        # github cli
    claude-code
    # Node from nixpkgs, pinned by flake.lock. Nothing here installs a system
    # package manager, so this is the only Node this configuration provides.
    nodejs_26
    # terminals
    wezterm
    # `ghostty` in nixpkgs is Linux-only; ghostty-bin is the upstream macOS
    # build and the only one that evaluates on Darwin. Verified against the
    # pinned nixpkgs - see tests/packages.test.sh, which fails if that changes.
    ghostty-bin
    # the font everything renders in
    nerd-fonts.hack
  ];

  fonts.fontconfig.enable = true;

  # GUI apps: symlinked into ~/Applications/Home Manager Apps, not copied.
  #
  # From stateVersion 25.11 on, Home Manager's Darwin default is `copyApps`,
  # which rsyncs the bundles so Spotlight indexes them - but that needs the
  # macOS "App Management" permission for the terminal, and on failure it calls
  # `tccutil reset` and aborts the whole activation. On a machine whose privacy
  # settings someone else administers that permission may simply not be
  # grantable, and losing the entire switch - shell, editor, git - over two
  # terminal emulators is the wrong trade. Symlinks need no permission at all.
  # The cost is that Spotlight does not index them; see README.md.
  targets.darwin.copyApps.enable = false;
  targets.darwin.linkApps.enable = true;

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
        [[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
      '')
    ];
    shellAliases = {
      ".." = "cd ..";
      "add" = "git add .";
      "push" = "git push";
      "pull" = "git pull";
      "m" = "git switch main";
      "cc" = "claude --dangerously-skip-permissions";
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
