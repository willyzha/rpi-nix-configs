{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------------------
  # SD Card Wear Prevention: Read-Only Partitions & Volatile RAM
  # ---------------------------------------------------------------------------

  # 1. Mount root (/) as Read-Only from the SD card.
  #    All system execution is read-only. Zero SD card wear during operation.
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = lib.mkForce [ "ro" "noatime" ];
  };

  # 2. Mount /boot/firmware (RPi boot files) as read-only.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "ro" "noatime" "nofail" "fmask=0137" "dmask=0027" ];
  };

  # 3. Mount /persist for state that MUST survive reboots
  #    (e.g., SSH host keys, Tailscale keys, container data).
  fileSystems."/persist" = {
    device = "/dev/disk/by-label/PERSIST";
    fsType = "ext4";
    options = [ "noatime" "nofail" "x-systemd.device-timeout=5s" ];
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
  #    and initializes directories and SSH host keys BEFORE local-fs.target.
  systemd.services.init-persist = {
    description = "Auto-initialize PERSIST partition on first boot";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "!/dev/disk/by-label/PERSIST";
    };
    after = [ "systemd-udev-settle.service" ];
    before = [ "local-fs.target" ];
    wantedBy = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "init-persist" ''
        set -euo pipefail

        # Determine root partition and parent disk
        ROOT_PART=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE / 2>/dev/null || true)
        if [ -z "$ROOT_PART" ]; then
          ROOT_PART="/dev/mmcblk0p2"
        fi
        DEV=$(${pkgs.util-linux}/bin/lsblk -npo PKNAME "$ROOT_PART" 2>/dev/null || true)
        if [ -z "$DEV" ]; then
          DEV="/dev/mmcblk0"
        fi

        echo "==> Root partition is $ROOT_PART on device $DEV"

        if [ -b "$DEV" ] && ! ${pkgs.util-linux}/bin/blkid -L PERSIST >/dev/null 2>&1; then
          echo "==> Auto-initializing PERSIST partition on $DEV..."
          # Append partition 3 using sfdisk to fill remaining SD card space
          echo ",,L" | ${pkgs.util-linux}/bin/sfdisk --append "$DEV" || true
          ${pkgs.parted}/bin/partprobe "$DEV" || true
          ${pkgs.util-linux}/bin/partx -u "$DEV" || true
          sleep 2

          PART="''${DEV}p3"
          if [ ! -b "$PART" ]; then
            PART="''${DEV}3"
          fi

          if [ -b "$PART" ]; then
            echo "==> Formatting $PART as ext4 with label PERSIST..."
            ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L PERSIST "$PART"
            ${pkgs.systemd}/bin/udevadm trigger --subsystem-match=block || true
            ${pkgs.systemd}/bin/udevadm settle || true
            sleep 1

            TMP_PERSIST="/mnt/init_persist"
            mkdir -p "$TMP_PERSIST"
            mount "$PART" "$TMP_PERSIST"

            mkdir -p \
              "$TMP_PERSIST/secrets" \
              "$TMP_PERSIST/secrets/wireguard" \
              "$TMP_PERSIST/etc/ssh" \
              "$TMP_PERSIST/var/lib/docker" \
              "$TMP_PERSIST/var/lib/tailscale" \
              "$TMP_PERSIST/var/lib/AdGuardHome" \
              "$TMP_PERSIST/docker"

            chmod 700 "$TMP_PERSIST/secrets" "$TMP_PERSIST/secrets/wireguard"

            # Pre-generate SSH host keys if missing
            if [ ! -f "$TMP_PERSIST/etc/ssh/ssh_host_ed25519_key" ]; then
              ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f "$TMP_PERSIST/etc/ssh/ssh_host_ed25519_key" -N "" -q
              ${pkgs.openssh}/bin/ssh-keygen -t rsa -b 4096 -f "$TMP_PERSIST/etc/ssh/ssh_host_rsa_key" -N "" -q
            fi

            # Pre-generate WireGuard keys if missing
            if [ ! -f "$TMP_PERSIST/secrets/wireguard/private.key" ]; then
              ${pkgs.wireguard-tools}/bin/wg genkey > "$TMP_PERSIST/secrets/wireguard/private.key"
              chmod 600 "$TMP_PERSIST/secrets/wireguard/private.key"
              ${pkgs.wireguard-tools}/bin/wg pubkey < "$TMP_PERSIST/secrets/wireguard/private.key" > "$TMP_PERSIST/secrets/wireguard/public.key"
            fi

            # Starter config stubs to avoid startup failures on optional secrets
            if [ ! -f "$TMP_PERSIST/secrets/keepalived-auth.conf" ]; then
              cat <<'EOF' > "$TMP_PERSIST/secrets/keepalived-auth.conf"
# VRRP authentication config (optional)
EOF
            fi

            if [ ! -f "$TMP_PERSIST/secrets/nut-monuser-password" ]; then
              echo "changeme" > "$TMP_PERSIST/secrets/nut-monuser-password"
              chmod 600 "$TMP_PERSIST/secrets/nut-monuser-password"
            fi

            umount "$TMP_PERSIST"
            rmdir "$TMP_PERSIST" || true
          fi
        fi

        ${pkgs.systemd}/bin/udevadm settle || true
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

      echo "==> Remounting / as Read-Write..."
      mount -o remount,rw /
      if mountpoint -q /boot/firmware; then
        mount -o remount,rw /boot/firmware || true
      fi

      cleanup() {
        echo "==> Restoring partitions to Read-Only..."
        if mountpoint -q /boot/firmware; then
          mount -o remount,ro /boot/firmware || true
        fi
        mount -o remount,ro / || true
      }
      trap cleanup EXIT

      echo "==> Applying NixOS configuration ($ACTION)..."
      nixos-rebuild "$ACTION" --flake "$FLAKE_TARGET"

      echo "==> Update complete. Partitions restored to Read-Only."
    '')
  ];
}
