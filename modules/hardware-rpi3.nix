{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot = {
    kernelPackages = lib.mkDefault pkgs.linuxKernel.packages.linux_rpi3;

    initrd.availableKernelModules = [
      "mmc_block"
      "bcm2835_dma"
      "usbhid"
      "usb_storage"
      "vc4"
    ];

    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    # Kernel parameters for quiet boot and console
    kernelParams = [
      "console=ttyAMA0,115200"
      "console=tty1"
    ];
  };

  # Enable Raspberry Pi hardware support
  hardware.enableRedistributableFirmware = true;
}
