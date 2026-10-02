{
  description = "NixOS configurations for Raspberry Pi nodes with zero-wear SD card protection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "aarch64-linux";
    in {
      nixosConfigurations = {
        # Primary Pi (192.168.1.11 - Pi 3B)
        kir-pi-primary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
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
            ./modules/sd-image.nix
            ./hosts/ott-pi-primary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };
      };

      # Direct image package shortcuts for easy building
      packages.${system} = {
        kir-pi-primary-image = self.nixosConfigurations.kir-pi-primary.config.system.build.sdImage;
        kir-pi-secondary-image = self.nixosConfigurations.kir-pi-secondary.config.system.build.sdImage;
        ott-pi-primary-image = self.nixosConfigurations.ott-pi-primary.config.system.build.sdImage;
      };
    };
}
