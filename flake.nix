{
  description = "Home-directory-only dotfiles for a managed Mac";

  # Standalone Home Manager, and nothing else. There is deliberately no
  # nix-darwin input: nix-darwin is the tool for configuring the *system*, and
  # this repo's whole premise is that it never touches one. See AGENTS.md.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      # === The one place to edit ==============================================
      # bootstrap.sh can rewrite both lines for you, and offers this machine's
      # real values as the defaults.

      # The account this configuration is built for.
      user = "john";

      # This account's home directory. null means "/Users/<user>", which is the
      # normal macOS layout. Set it explicitly when a managed Mac puts the home
      # directory somewhere else - a network account under /Users/<domain>_<name>,
      # or a mobile account mounted elsewhere. Activation refuses to run against
      # the wrong directory rather than quietly building someone else's home.
      homeDirectory = null;
      # =======================================================================

      # Both Darwin architectures are built from the same source. Corporate
      # fleets still hand out Intel Macs, so neither is the "real" one and
      # nothing here has to be edited to move between them: the scripts detect
      # the architecture and pick the matching output.
      systems = [ "aarch64-darwin" "x86_64-darwin" ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkHome = system:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs { inherit system; };
          extraSpecialArgs = { inherit user homeDirectory; };
          modules = [ ./home.nix ];
        };
    in
    {
      homeConfigurations = builtins.listToAttrs (map (system: {
        name = "${user}@${system}";
        value = mkHome system;
      }) systems);

      # `nix flake check` knows nothing about homeConfigurations, so the
      # activation package is exposed here as well. That is what makes a plain
      # `nix flake check` evaluate this configuration for both architectures
      # instead of silently checking nothing.
      packages = forAllSystems (system: {
        default = self.homeConfigurations."${user}@${system}".activationPackage;

        # The Home Manager CLI at the exact revision flake.lock pins, so
        # `nix run ~/.dotfiles#home-manager -- switch` runs the same version
        # that built the configuration. The usual `nix run home-manager/<branch>`
        # takes the tool from a branch head while the config comes from the
        # lock, and those two can disagree.
        home-manager = home-manager.packages.${system}.home-manager;
      });
    };
}
