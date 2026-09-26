{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  # SD Card Image Build Options
  sdImage = {
    # Compress with zstd for fast download and small GitHub Release file size
    compressImage = true;
    imageName = "${config.networking.hostName}-nixos.img";
    # Do not auto-expand root partition to 100% on boot; leaves room for /persist
    expandOnBoot = false;
  };

  # Since expandOnBoot is disabled, run initial registration without partition resizing
  boot.postBootCommands = lib.mkAfter ''
    if [ -f /nix-path-registration ]; then
      set -euo pipefail
      echo "==> Registering initial Nix store closure..."
      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration || true
      touch /etc/NIXOS || true
      ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system || true
      rm -f /nix-path-registration || true
    fi
  '';
}
