{
  description = "Patchwork Labs infrastructure: org hosts and shared NixOS modules";

  # This repo is public and must stay buildable by every org admin, so it never
  # takes jaspermayone/infra (private) as an input. The dependency goes the
  # other way: infra imports nixosModules from here.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs, ... }:
    {
      nixosModules = {
        # The Weave service module alone, with no instance settings.
        weave = ./modules/weave;
        # Weave as it runs on alastor: instance settings, deploy key, Traefik
        # routes and agenix secrets. infra's alastor imports this one.
        weave-alastor = ./hosts/alastor/weave.nix;
      };

      # nixos-rebuild switch --flake github:patchworklabsorg/core#pw-01-core --target-host ...
      nixosConfigurations.pw-01-core = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/pw-01-core/configuration.nix ];
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
