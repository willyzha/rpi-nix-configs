{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # SD Card Wear Prevention: Read-Only Partitions & Volatile RAM
  # ---------------------------------------------------------------------------

  # 1. Mount root (/) as Read-Only from the SD card.
  #    All system execution is read-only. Zero SD card wear during operation.
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "ro" "noatime" ];
  };

  # 2. Mount /boot/firmware (RPi boot files) as read-only.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "ro" "noatime" "fmask=0137" "dmask=0027" ];
  };

  # 3. Mount /persist for state that MUST survive reboots
  #    (e.g., SSH host keys, Tailscale keys, container data).
  fileSystems."/persist" = {
    device = "/dev/disk/by-label/PERSIST";
    fsType = "ext4";
    options = [ "noatime" ];
    neededForBoot = false;
  };

  # 4. Volatile system logging: logs are kept in RAM only (max 32MB)
  #    Preventing constant background writes from journald.
  services.journald.extraConfig = ''
    Storage=volatile
    RuntimeMaxUse=32M
  '';

  # 5. Put /tmp on tmpfs in RAM
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "256M";

  # 6. Persist SSH host keys so SSH client fingerprints don't change on reboot
  services.openssh.hostKeys = [
    {
      path = "/persist/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
    {
      path = "/persist/etc/ssh/ssh_host_rsa_key";
      type = "rsa";
      bits = 4096;
    }
  ];

  # 7. Persist machine-id (if present)
  environment.etc."machine-id".source = lib.mkIf (builtins.pathExists "/persist/etc/machine-id") "/persist/etc/machine-id";

  # 8. Ensure critical persistence directories exist on boot
  systemd.tmpfiles.rules = [
    "d /persist/etc/ssh 0755 root root -"
    "d /persist/secrets 0700 root root -"
    "d /persist/secrets/wireguard 0700 root root -"
    "d /persist/var/lib/docker 0710 root root -"
    "d /persist/var/lib/tailscale 0700 root root -"
    "d /persist/var/lib/AdGuardHome 0755 root root -"
    "d /persist/docker 0755 root root -"
  ];

  # 9. Automatic first-boot initialization for /persist
  #    Detects unallocated space on the SD card, creates partition 3, formats it,
  #    and initializes directories and SSH host keys automatically.
  systemd.services.init-persist = {
    description = "Auto-initialize PERSIST partition on first boot";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!/dev/disk/by-label/PERSIST";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "init-persist" ''
        set -euo pipefail
        DEV="/dev/mmcblk0"
        if [ -b "$DEV" ] && ! ${pkgs.util-linux}/bin/blkid -L PERSIST >/dev/null 2>&1; then
          echo "==> Auto-initializing PERSIST partition on $DEV..."
          mount -o remount,rw / || true
          ${pkgs.parted}/bin/parted -s "$DEV" mkpart primary ext4 5500MiB 100% || true
          ${pkgs.util-linux}/bin/partx -u "$DEV" || true
          sleep 2
          PART="''${DEV}p3"
          if [ -b "$PART" ]; then
            ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L PERSIST "$PART"
            mkdir -p /persist
            mount "$PART" /persist
            mkdir -p /persist/secrets /persist/etc/ssh /persist/var/lib/docker /persist/var/lib/tailscale /persist/var/lib/AdGuardHome
            if [ ! -f /persist/etc/ssh/ssh_host_ed25519_key ]; then
              ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /persist/etc/ssh/ssh_host_ed25519_key -N ""
              ${pkgs.openssh}/bin/ssh-keygen -t rsa -b 4096 -f /persist/etc/ssh/ssh_host_rsa_key -N ""
            fi
            umount /persist || true
          fi
          mount -o remount,ro / || true
        fi
      '';
    };
  };

  # 10. Helper command to safely rebuild & switch generations.
  #     Automatically remounts / and /boot/firmware read-write,
  #     runs the nixos rebuild, and locks them back down as read-only.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "rpi-rebuild" ''
      #!/usr/bin/env bash
      set -euo pipefail

      ACTION="''${1:-switch}"
      FLAKE_TARGET="''${2:-.#}"

      echo "==> Remounting / and /boot/firmware as Read-Write..."
      mount -o remount,rw /
      mount -o remount,rw /boot/firmware

      cleanup() {
        echo "==> Remounting / and /boot/firmware as Read-Only..."
        mount -o remount,ro /boot/firmware || true
        mount -o remount,ro / || true
      }
      trap cleanup EXIT

      echo "==> Applying NixOS configuration ($ACTION)..."
      nixos-rebuild "$ACTION" --flake "$FLAKE_TARGET"

      echo "==> Update complete. Partitions restored to Read-Only."
    '')
  ];
}
