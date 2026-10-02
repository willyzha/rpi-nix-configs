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
        pi-primary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/sd-image.nix
            ./hosts/pi-primary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };

        # Secondary Pi (192.168.1.12 - Pi 3B)
        pi-secondary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/sd-image.nix
            ./hosts/pi-secondary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };

        # Remote Pi (Ottawa)
        pi-remote = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/sd-image.nix
            ./hosts/pi-remote/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };
      };

      # Direct image package shortcuts for easy building
      packages.${system} = {
        pi-primary-image = self.nixosConfigurations.pi-primary.config.system.build.sdImage;
        pi-secondary-image = self.nixosConfigurations.pi-secondary.config.system.build.sdImage;
        pi-remote-image = self.nixosConfigurations.pi-remote.config.system.build.sdImage;
      };
    };
}
