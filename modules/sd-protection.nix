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

  # 5. Put /tmp and /var/cache on tmpfs in RAM
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "256M";

  # Volatile cache in RAM: prevents wear and allows services with CacheDirectory= to start on read-only root
  fileSystems."/var/cache" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "noatime" "mode=0755" "size=64M" ];
  };

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
          echo "==> Auto-initializing SD card layout (12GB system, remaining PERSIST)..."

          # 1. Expand Partition 2 (root system) to 12GB
          printf "Yes\n" | ${pkgs.parted}/bin/parted ---pretend-input-tty "$DEV" resizepart 2 12GB || true
          ${pkgs.parted}/bin/partprobe "$DEV" || ${pkgs.util-linux}/bin/partx -u "$DEV" || true
          ${pkgs.util-linux}/bin/mount -o remount,rw / || true
          ${pkgs.e2fsprogs}/bin/resize2fs "$ROOT_PART" || true

          # 2. Create Partition 3 (PERSIST) with remaining SD card space
          ${pkgs.parted}/bin/parted -s "$DEV" mkpart primary ext4 12GB 100% || true
          ${pkgs.parted}/bin/partprobe "$DEV" || ${pkgs.util-linux}/bin/partx -a "$DEV" || true
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

            if [ ! -f "$TMP_PERSIST/secrets/rclone-pass" ]; then
              echo "changeme" > "$TMP_PERSIST/secrets/rclone-pass"
              chmod 600 "$TMP_PERSIST/secrets/rclone-pass"
            fi

            # Container persistence directories and volume stubs
            mkdir -p \
              "$TMP_PERSIST/docker/swag/config" \
              "$TMP_PERSIST/docker/swag/logrotate/logrotate.d" \
              "$TMP_PERSIST/docker/nut_server/upswake/upswake-rules" \
              "$TMP_PERSIST/docker/portainer/data" \
              "$TMP_PERSIST/docker/python_container" \
              "$TMP_PERSIST/docker/rclone/config" \
              "$TMP_PERSIST/docker/rclone/downloads" \
              "$TMP_PERSIST/home/pi"

            if [ ! -f "$TMP_PERSIST/docker/swag/logrotate/logrotate.conf" ]; then
              touch "$TMP_PERSIST/docker/swag/logrotate/logrotate.conf" \
                    "$TMP_PERSIST/docker/swag/logrotate/logrotate.d/fail2ban" \
                    "$TMP_PERSIST/docker/swag/logrotate/logrotate.d/lerotate" \
                    "$TMP_PERSIST/docker/swag/logrotate/logrotate.d/nginx" \
                    "$TMP_PERSIST/docker/swag/logrotate/logrotate.d/php-fpm"
            fi

            if [ ! -f "$TMP_PERSIST/docker/nut_server/upswake/upswake-config.yaml" ]; then
              cat <<'EOF' > "$TMP_PERSIST/docker/nut_server/upswake/upswake-config.yaml"
# UPSWake starter config
server:
  host: "127.0.0.1"
  port: 3493
EOF
            fi

            if [ ! -f "$TMP_PERSIST/docker/python_container/run.sh" ]; then
              cat <<'EOF' > "$TMP_PERSIST/docker/python_container/run.sh"
#!/bin/sh
echo "Container started."
sleep infinity
EOF
              chmod +x "$TMP_PERSIST/docker/python_container/run.sh"
            fi

            umount "$TMP_PERSIST"
            rmdir "$TMP_PERSIST" || true
          fi
        fi

        # Pre-create mount point directories on root filesystem for bind mounts
        ${pkgs.util-linux}/bin/mount -o remount,rw / || true
        mkdir -p /persist /var/lib/tailscale /var/lib/AdGuardHome /var/lib/docker
        ${pkgs.util-linux}/bin/mount -o remount,ro / || true

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
      nixos-rebuild "$ACTION" --refresh --flake "$FLAKE_TARGET"

      echo "==> Update complete. Partitions restored to Read-Only."
    '')
  ];
}
