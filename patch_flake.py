import re

with open('flake.nix', 'r') as f:
    content = f.read()

target = """        # Secondary Pi (192.168.1.12 - Pi 3B)
        pi-secondary = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/sd-image.nix
            ./hosts/pi-secondary/default.nix
            ({ ... }: {
              system.configurationRevision = self.rev or self.dirtyRev or null;
            })
          ];
        };"""

new_block = target + """

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
        };"""

content = content.replace(target, new_block)

# Also add to packages
packages_target = """        pi-secondary-image = self.nixosConfigurations.pi-secondary.config.system.build.sdImage;"""
packages_new = packages_target + """
        pi-remote-image = self.nixosConfigurations.pi-remote.config.system.build.sdImage;"""
content = content.replace(packages_target, packages_new)

with open('flake.nix', 'w') as f:
    f.write(content)
