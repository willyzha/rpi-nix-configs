{
  description = "NixOS configurations for Raspberry Pi nodes with zero-wear SD card protection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, ... }:
    let
      system = "aarch64-linux";
      tailscaleOverlay = final: prev: {
        tailscale = nixpkgs-unstable.legacyPackages.${prev.system}.tailscale;
      };
    in {
      nixosConfigurations = {
        # Primary Pi (192.168.1.11 - Pi 3B)
        kir-pi-primary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ tailscaleOverlay ]; }
            ./modules/sd-image.nix
            ./hosts/kir-pi-primary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };

        # Secondary Pi (192.168.1.12 - Pi 3B)
        kir-pi-secondary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ tailscaleOverlay ]; }
            ./modules/sd-image.nix
            ./hosts/kir-pi-secondary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };

        # Remote Pi (Ottawa)
        ott-pi-primary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.overlays = [ tailscaleOverlay ]; }
            ./modules/sd-image.nix
            ./hosts/ott-pi-primary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };

        # Legacy aliases for seamless backwards-compatible deployments
        pi-primary = self.nixosConfigurations.kir-pi-primary;
        pi-secondary = self.nixosConfigurations.kir-pi-secondary;
        ott-pi = self.nixosConfigurations.ott-pi-primary;
        pi-remote = self.nixosConfigurations.ott-pi-primary;
      };

      # Direct image package shortcuts for easy building
      packages.${system} = {
        kir-pi-primary-image = self.nixosConfigurations.kir-pi-primary.config.system.build.sdImage;
        kir-pi-secondary-image = self.nixosConfigurations.kir-pi-secondary.config.system.build.sdImage;
        ott-pi-primary-image = self.nixosConfigurations.ott-pi-primary.config.system.build.sdImage;
      };

      # Standard flake formatter for 'nix fmt'
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixpkgs-fmt;
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;
    };
}
