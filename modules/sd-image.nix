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
  };
}
