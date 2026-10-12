{
  description = "The Patchwork Labs Core VM (pw-01-core)";

  # This repo holds the Core VM only. Patchwork services and their modules
  # live in patchworklabsorg/infra. This repo is public, so it never takes
  # jaspermayone/infra (private) as an input.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    {
      # nixos-rebuild switch --flake github:patchworklabsorg/core#pw-01-core --target-host ...
      nixosConfigurations.pw-01-core = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/pw-01-core/configuration.nix ];
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
