{ config, lib, pkgs, user, homeDirectory, brew-src, brewVersion, ... }:

let
  # Where this repository lives. bootstrap.sh points ~/.dotfiles at it, and the
  # out-of-store symlinks below resolve through that name rather than through
  # wherever the clone happens to sit.
  dotfiles = "${config.home.homeDirectory}/.dotfiles";

  # npm's global prefix. The Nix node's own prefix is a read-only store path, so
  # `npm install -g` needs somewhere writable, and that somewhere has to be
  # inside $HOME: /usr/local is not this configuration's to write.
  npmPrefix = "${config.home.homeDirectory}/.npm-global";

  # === Homebrew, as a Nix package ============================================
  #
  # Homebrew itself comes from the `brew-src` flake input: its code lives in the
  # Nix store, flake.lock pins the commit, and the prefix holds nothing but a
  # symlink pointing at it. There is no git checkout in /opt for `brew update`
  # to fast-forward, so the Homebrew this Mac runs is the Homebrew flake.lock
  # says it is until someone changes the lock.
  #
  # The mechanism is a port of nix-homebrew's, which is the thing the owner's
  # personal configuration uses and which does not apply here: nix-homebrew
  # ships exactly one output, a nix-darwin module, and it writes
  # `system.activationScripts` and `environment.systemPackages` and asserts on
  # `system.primaryUser`. None of those exist in standalone Home Manager, and
  # importing the module would mean importing nix-darwin, which is the one thing
  # this repository must never do. So the technique is ported, not the module -
  # patch the store copy, generate a prefix-specific `bin/brew`, do the
  # privileged prefix creation exactly once, and do everything else as the user.
  #
  #   BSD 2-Clause License
  #   Copyright (c) 2023 Zhaofeng Li and the nix-homebrew contributors
  #
  # AGENTS.md carries the design rule this narrows and README.md says the same
  # thing to a user. tests/safety.test.sh and tests/homebrew.test.sh hold what
  # is left.

  # Where this Mac's Homebrew goes. Decided by the architecture and by nothing
  # else, because Homebrew's prebuilt bottles are built for these two prefixes
  # and a Homebrew anywhere else compiles everything from source. That is also
  # the rule lib/homebrew-present.sh applies at runtime, and
  # tests/homebrew.test.sh compares the two.
  homebrewPrefix =
    if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew" else "/usr/local";

  # On Intel the prefix is /usr/local, shared with everything else on the
  # machine, so Homebrew keeps its library one level down. Upstream Homebrew's
  # layout, not a choice made here.
  homebrewLibrary =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "/opt/homebrew/Library"
    else "/usr/local/Homebrew/Library";

  # Homebrew shells out to git for taps and for anything it fetches, and the
  # generated `brew` below hands it a PATH of exactly this plus the system
  # directories. nix-homebrew's list, and its note: coreutils is deliberately
  # not on it, because the GNU implementations behave differently from the
  # macOS ones Homebrew is written against.
  brewRuntimePath = lib.makeBinPath [ pkgs.gitMinimal ];

  # Homebrew's Ruby. Homebrew 6 requires Ruby 4.0 and would otherwise download a
  # "portable Ruby" of its own into the prefix at first run - a binary from the
  # network, outside the lock, which is exactly what pinning it here avoids.
  brewRuby = pkgs.ruby_4_0;

  # The patched copy of Homebrew, ported from nix-homebrew's `patchBrew`.
  #
  # Three changes, and each one exists to cut a link between the code in the
  # store and something outside it:
  #
  #   - `brew update` no longer walks HOMEBREW_REPOSITORY. That loop is
  #     Homebrew updating itself, and the copy here is read-only and pinned;
  #   - `setup-ruby-path` is replaced so Homebrew uses the nixpkgs Ruby instead
  #     of downloading a portable one. Homebrew runs Ruby with gems disabled and
  #     inserts its vendored libraries into LOAD_PATH, so the way to satisfy the
  #     one gem that is then missing is to add it to LOAD_PATH too, which is
  #     what the line appended to bundler's setup.rb does;
  #   - the version is embedded, so `brew --version` and Homebrew's user agent
  #     do not have to ask a git repository that is not there.
  #
  # That last one departs from nix-homebrew's spelling, deliberately and
  # visibly. nix-homebrew rewrites two assignments in brew.sh with sed, and in
  # Homebrew 6.0.22 neither of those lines exists any more - the version is
  # worked out by `set-homebrew-version-from-git` in utils/git.sh. A sed that
  # matches nothing does nothing and says nothing, which is the worst outcome
  # available, so the function is overridden instead, the same way this file
  # overrides `setup-ruby-path`. Both overrides assert that the thing they are
  # replacing is really there, so a future Homebrew that renames either one
  # fails this build rather than silently losing the patch.
  patchedBrew = pkgs.runCommandLocal "brew-${brewVersion}-patched" { } ''
    cp -r "${brew-src}" "$out"
    chmod u+w "$out" "$out/Library/Homebrew" "$out/Library/Homebrew/cmd"

    # Disable self-update behavior
    substituteInPlace "$out/Library/Homebrew/cmd/update.sh" \
      --replace-fail 'for DIR in "''${HOMEBREW_REPOSITORY}"' "for DIR in "

    # Disable vendored Ruby
    #
    # Homebrew passes --disable=gems,rubyopt ($HOMEBREW_RUBY_DISABLE_OPTIONS)
    # and inserts vendored libraries into LOAD_PATH (vendor/bundle/bundler/setup.rb,
    # standalone/init.rb). Instead of re-enabling gems, we add in additional
    # required gems into LOAD_PATH.
    ruby_sh="$out/Library/Homebrew/utils/ruby.sh"
    bundler_setup_rb="$out/Library/Homebrew/vendor/bundle/bundler/setup.rb"
    grep -q "setup-ruby-path" "$ruby_sh" \
      || { echo "utils/ruby.sh no longer defines setup-ruby-path" >&2; exit 1; }
    chmod u+w "$ruby_sh" "$bundler_setup_rb"
    echo -e "setup-ruby-path() { export HOMEBREW_RUBY_PATH=\"${brewRuby}/bin/ruby\"; }" >>"$ruby_sh"
    echo -e "$:.unshift \"${brewRuby.gems.fiddle}/${brewRuby.gemPath}/gems/fiddle-${brewRuby.gems.fiddle.version}/lib\"" >>"$bundler_setup_rb"

    # Embed the version instead of deriving it from a git repository that this
    # layout deliberately does not have.
    git_sh="$out/Library/Homebrew/utils/git.sh"
    grep -q "set-homebrew-version-from-git" "$git_sh" \
      || { echo "utils/git.sh no longer defines set-homebrew-version-from-git" >&2; exit 1; }
    chmod u+w "$git_sh"
    echo "set-homebrew-version-from-git() { HOMEBREW_VERSION=\"${brewVersion}\"; }" >>"$git_sh"
  '';

  # The generated `bin/brew`, ported from nix-homebrew's `makeBinBrew`.
  #
  # Upstream's own `bin/brew` is a header that works out where Homebrew is,
  # followed by ~200 lines that set up its environment and exec `brew.sh`. This
  # replaces the header - no prefix, library or repository auto-detection,
  # everything decided here - and keeps the tail exactly as the pinned source
  # writes it.
  #
  # The tail is sliced out of `brew-src` at build time rather than vendored.
  # nix-homebrew keeps a copy of those lines in its tree plus a script to
  # refresh it; taking the slice here means there is no copy in this repository
  # to fall out of date with the pin. It is the same slice that script makes:
  # everything after the last line upstream's header writes, with the runtime
  # PATH prepended to the single PATH assignment in it.
  #
  # Every assumption the slice rests on is asserted, so a future Homebrew that
  # reshapes bin/brew fails this build instead of producing a launcher that is
  # quietly truncated or missing git.
  #
  # Three things about the result are load bearing:
  #
  #   - the `#!/bin/bash` shebang is left exactly as written. nix-homebrew's
  #     reason: patching it breaks `arch -x86_64 /usr/local/bin/brew` on Apple
  #     silicon. `runCommandLocal` runs no fixup phase, so nothing here rewrites
  #     it, and tests/homebrew.test.sh reads the first line back to be sure;
  #   - HOMEBREW_REPOSITORY points at a directory that is not a git repository
  #     and says so in its name. Homebrew expects a repository to exist; it does
  #     not need one that works, because nothing here ever updates itself;
  #   - HOMEBREW_NO_AUTO_UPDATE is deliberately absent, in either direction.
  #     nix-homebrew sets it when it pins the taps; no taps are pinned here, so
  #     there is nothing to protect - and this repository's standing rule is
  #     that it never touches that variable, because a slow or proxied network
  #     is exactly why someone would set it themselves. Auto-update has nothing
  #     to fast-forward in a read-only store copy in any case.
  #
  # No taps are declared, so Homebrew uses its JSON API, as it does by default.
  # Pinning homebrew-core and homebrew-cask would drag two very large
  # repositories into flake.lock to buy a reproducibility this configuration
  # does not claim anyway: the Brewfile names formulae, and Homebrew picks the
  # versions.
  binBrew = pkgs.runCommandLocal "brew" {
    # Passed through the environment, so `printf '%s'` writes it out verbatim
    # and the `$HOMEBREW_LIBRARY` below stays a reference Homebrew expands at
    # run time rather than something this build expands.
    header = ''
      #!/bin/bash
      export HOMEBREW_PREFIX="${homebrewPrefix}"
      export HOMEBREW_LIBRARY="${homebrewLibrary}"
      export HOMEBREW_REPOSITORY="$HOMEBREW_LIBRARY/.homebrew-is-managed-by-nix"
      export HOMEBREW_BREW_FILE="@out@"

      # Homebrew itself cannot self-update, so we set
      # fake before/after versions to make `update-report.rb` happy
      export HOMEBREW_UPDATE_BEFORE="nix"
      export HOMEBREW_UPDATE_AFTER="nix"
    '';
  } ''
    src="${brew-src}/bin/brew"

    grep -c '^HOMEBREW_LIBRARY=' "$src" | grep -qx 1 \
      || { echo "bin/brew no longer has exactly one HOMEBREW_LIBRARY= line" >&2; exit 1; }
    grep -c '^PATH="' "$src" | grep -qx 1 \
      || { echo "bin/brew no longer has exactly one PATH= line" >&2; exit 1; }

    {
      printf '%s' "$header" | sed -e "s|@out@|$out|"
      sed \
        -e '1,/^HOMEBREW_LIBRARY=/d' \
        -e 's|^PATH="|PATH="${brewRuntimePath}:|' \
        "$src"
    } >"$out"

    grep -q 'exec /usr/bin/env -i' "$out" \
      || { echo "the sliced bin/brew tail does not end in Homebrew's exec" >&2; exit 1; }
    grep -q "^PATH=\"${brewRuntimePath}:" "$out" \
      || { echo "the runtime PATH was not prepended, so Homebrew would have no git" >&2; exit 1; }
    head -n1 "$out" | grep -qx '#!/bin/bash' \
      || { echo "the generated brew does not start with #!/bin/bash" >&2; exit 1; }

    chmod +x "$out"
  '';

  # The unprivileged half of the setup, which runs on every switch.
  #
  # It writes three things into a prefix bootstrap.sh has already created and
  # handed to this user: the symlink that makes $HOMEBREW_LIBRARY/Homebrew the
  # patched store copy, the empty directory Homebrew expects to find a
  # repository at, and the symlink that makes $HOMEBREW_PREFIX/bin/brew the
  # launcher above. None of it needs root, and if the prefix is not in a state
  # where that is true it fails and says to run ./bootstrap.sh.
  #
  # The rules it applies are lib/homebrew-present.sh's, sourced out of the Nix
  # store rather than reimplemented here, so bootstrap.sh's preflight and this
  # step cannot reach different verdicts about the same prefix.
  #
  # The two store paths are named on their own lines rather than inlined into
  # the call, because tests/safety.test.sh reads them back out of the built
  # artifact to decide what it has to scan.
  homebrewPrefixSetup = pkgs.writeShellScript "dotfiles-work-homebrew-prefix" ''
    set -eu

    . ${./lib/homebrew-present.sh}

    brew_code="${patchedBrew}/Library/Homebrew"
    bin_brew="${binBrew}"

    dotfiles_homebrew_prefix_link \
      "${homebrewPrefix}" "${homebrewLibrary}" "$brew_code" "$bin_brew"
  '';

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

  # The Brewfile step, as a script rather than inline activation text, so that
  # its behaviour can be executed and asserted on directly - what it passes
  # `brew`, what it does with the cleanup variables, and a missing `brew`.
  # tests/homebrew.test.sh runs this very file against a recording stand-in.
  brewBundle = pkgs.writeShellScript "dotfiles-work-brew-bundle" ''
    set -eu

    # The prefix this configuration manages, passed in rather than worked out
    # here. home.nix already knows it - it is the same value the prefix-setup
    # step was given - and taking it as an argument is what lets the tests point
    # both this and HOMEBREW_PREFIX at one temp directory and still exercise the
    # real step. Baking it would make every stand-in run fail the check below
    # for a reason that has nothing to do with what the test is about.
    if [ "$#" != 1 ]; then
      echo "dotfiles-work: this step takes the Homebrew prefix it manages as" >&2
      echo "       its only argument. Home Manager's activation passes it." >&2
      exit 2
    fi
    managed_prefix=$1

    brewfile="$HOME/${brewfileTarget}"

    # Where to find the `brew` this step hands the Brewfile to.
    #
    # The same library the prefix-setup step sources, and for the same reason:
    # this search used to be written out here as well, and the two copies drifting
    # is not hypothetical - one of them fed a space-separated string to an
    # unquoted `for`, so a HOMEBREW_PREFIX containing a space split into two
    # paths that do not exist, and bootstrap refused a Mac the rebuild would
    # have accepted. There is one copy now.
    #
    # It is a different question from the one the prefix-setup step answers, and
    # it stays a different question. Setup decides where this configuration's
    # Homebrew BELONGS - architecture, and nothing else. This decides where to
    # LOOK, and it honours HOMEBREW_PREFIX, which is Homebrew's own answer to
    # "where am I": a machine that has been told where Homebrew is and does not
    # have it there is a machine without a usable Homebrew, and saying so is
    # better than quietly using a different one. On an ordinary machine the two
    # answers coincide, and tests/homebrew.test.sh asserts that they do.
    #
    # PATH is not consulted, because it cannot be: Home Manager's activation
    # script replaces PATH with a fixed list of Nix store paths before running
    # this, so the user's shell PATH is not visible here at all. What is visible
    # is the rest of their environment, which is where HOMEBREW_PREFIX comes
    # from - every shell set up by `brew shellenv` exports it.
    #
    # That branch is also the only lever that makes the missing-Homebrew failure
    # path below reachable in a test on a machine that *has* Homebrew, which is
    # every CI runner - macos-latest ships it preinstalled.
    # tests/homebrew.test.sh:test_a_missing_homebrew_fails_with_an_explanation
    # points HOMEBREW_PREFIX at an empty directory for exactly that purpose. It
    # has been proposed as a redundant second acceptance path and kept
    # deliberately: dropping it would trade a working guarantee for a tidier
    # line.
    #
    # What the variable no longer buys is the right to send the Brewfile
    # anywhere at all - see the refusal below.
    . ${./lib/homebrew-present.sh}

    brew=$(dotfiles_homebrew_find)

    if [ -z "$brew" ]; then
      echo "dotfiles-work: no Homebrew at $(dotfiles_homebrew_searched), so its part of this" >&2
      cat >&2 <<'MISSING'
    configuration cannot be applied.

    This configuration installs its own Homebrew, from the version flake.lock
    pins, into the prefix ./bootstrap.sh creates. Reaching this message means
    that prefix is not where this step looked - either ./bootstrap.sh has never
    run on this Mac, or HOMEBREW_PREFIX is pointing somewhere else.

    Run ./bootstrap.sh, which says what it finds and what it will do about it.
    There is no way to opt out of this step: emptying the `brews` and `casks`
    lists in home.nix does not turn it off, it only leaves it with nothing to
    install.
    MISSING
      exit 1
    fi

    # The second door, and it is shut on every switch rather than once at
    # bootstrap.
    #
    # bootstrap.sh's preflight refuses a Mac whose Homebrew is somewhere else,
    # but a preflight only runs when someone runs it. A user who adds Homebrew's
    # shellenv line AFTER a successful setup - or installs a second Homebrew -
    # points HOMEBREW_PREFIX at it, and every later rebuild would hand the whole
    # Brewfile to a Homebrew this configuration does not manage: formulae and
    # casks into someone else's prefix, `--force` replacing apps there, and the
    # prefix the one password paid for left empty. Silently, with a zero exit.
    #
    # So this asks the same question the preflight asks, through the same
    # function, and stops. Not a warning that carries on: the whole value of the
    # check is that nothing installs into an unmanaged Homebrew.
    if ! dotfiles_homebrew_is_managed_brew "$managed_prefix" "$brew"; then
      echo "dotfiles-work: refusing to hand the Brewfile to a Homebrew this" >&2
      echo "       configuration does not manage." >&2
      dotfiles_homebrew_report_elsewhere "       " "$managed_prefix" "$brew"
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
    # It is also what markdown-preview.nvim's build step runs on, so removing it
    # breaks that plugin's install as well as `npm install -g`.
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
  # The other two edges are there because these steps can fail on a machine
  # whose Homebrew prefix is missing or not the user's, activation runs under
  # `set -eu`, and a failure here must not take anything else down with it.
  # `installPackages` is what makes true the promise README.md, HOW-TO.md and
  # bootstrap.sh all make, that when the Homebrew half fails everything Nix
  # installs has already been applied.
  # `onFilesChange` is the one that would not self-heal: it holds the font
  # rsync into ~/Library/Fonts, guarded by a marker file that `linkGeneration`
  # has already placed in $HOME by the time this runs. Fail in between and the
  # next rebuild finds the marker matching, decides nothing changed, and skips
  # the rsync forever - so the font is never installed and the prompt renders
  # tofu until the font derivation itself changes.
  #
  # This and the prefix step above are where this repository stops being
  # contained by the home directory. The prefix step writes into /opt/homebrew
  # or /usr/local - into a directory bootstrap.sh has already made the user's,
  # so still without root - and this step asks Homebrew to install into that
  # prefix and into /Applications. README.md says so in the same words;
  # AGENTS.md records what the design rule now is, and tests/safety.test.sh
  # asserts the part of it that still holds.
  home.file."${brewfileTarget}".text = brewfile;

  # Unconditional, both of them. This configuration installs and requires
  # Homebrew, and emptying the lists above is not a way to opt out: the prefix
  # is still set up, the Brewfile step still runs, and it asks Homebrew to
  # install nothing.
  #
  # Two steps, and the edge between them is the load-bearing part. The prefix
  # setup is what puts a `brew` at $HOMEBREW_PREFIX/bin/brew, so it has to run
  # before the step that looks for one. Home Manager breaks an unconstrained tie
  # by attribute name and "homebrewBundle" sorts ahead of "homebrewPrefix", so
  # without the explicit edge the order would be exactly backwards - and on a
  # first switch the bundle step would report a missing Homebrew that the very
  # next step was about to install.
  home.activation.homebrewPrefix =
    lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" "installPackages" "onFilesChange" ]
      "run ${homebrewPrefixSetup}";

  home.activation.homebrewBundle =
    lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" "installPackages" "onFilesChange" "homebrewPrefix" ]
      "run ${brewBundle} ${homebrewPrefix}";

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
