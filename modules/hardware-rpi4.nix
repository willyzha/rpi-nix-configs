{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot = {
    kernelPackages = lib.mkDefault pkgs.linuxKernel.packages.linux_rpi4;
    supportedFilesystems = lib.mkForce [ "ext4" "vfat" ];

    initrd.availableKernelModules = [
      "mmc_block"
      "bcm2835_dma"
      "usbhid"
      "usb_storage"
      "vc4"
      "pcie_brcmstb" # Required for Pi 4 USB/Ethernet
      "reset-raspberrypi" # Required for Pi 4 USB/Ethernet
    ];

    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };

    # Kernel parameters: use ttyS0 for GPIO serial and tty1 for display.
    # Do NOT include ttyAMA0 because on Raspberry Pi 3/4 ttyAMA0 is wired to Bluetooth!
    kernelParams = lib.mkForce [
      "console=ttyS0,115200n8"
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
