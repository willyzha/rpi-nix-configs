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

  # Fix: modprobe: FATAL: Module ahci not found in directory
  # On Raspberry Pi kernels, PC/SATA modules like ahci are not present.
  # This overlay instructs makeModulesClosure to allow missing modules.
  nixpkgs.overlays = [
    (_final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  # Enable Raspberry Pi hardware support
  hardware.enableRedistributableFirmware = true;
}
