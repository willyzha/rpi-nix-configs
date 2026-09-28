{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot = {
    kernelPackages = lib.mkDefault pkgs.linuxKernel.packages.linux_rpi3;

    initrd = {
      includeDefaultModules = true;
      kernelModules = [
        "bcm2835"
        "sdhci-iproc"
        "mmc_block"
        "ext4"
      ];
      availableKernelModules = [
        "bcm2835"
        "sdhci-iproc"
        "mmc_block"
        "bcm2835_dma"
        "usbhid"
        "usb_storage"
        "uas"
        "sd_mod"
        "vc4"
        "ext4"
      ];
    };

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

  # Fix: ensure kmod.out (modprobe/depmod) is in PATH and nativeBuildInputs
  # for makeModulesClosure, and allowMissing is true to safely handle custom RPi modules.
  nixpkgs.overlays = [
    (_final: super: {
      makeModulesClosure = x: (super.makeModulesClosure (x // { allowMissing = true; })).overrideAttrs (old: {
        nativeBuildInputs = [ (super.buildPackages.kmod or super.kmod).out ] ++ (old.nativeBuildInputs or [ ]);
        preHook = ''
          export PATH="${(super.buildPackages.kmod or super.kmod).out}/bin:${(super.buildPackages.kmod or super.kmod).out}/sbin:$PATH"
        '';
      });
    })
  ];

  # Enable Raspberry Pi hardware support
  hardware.enableRedistributableFirmware = true;
}
