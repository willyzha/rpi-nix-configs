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

  # Volatile daemon socket in RAM: allows nix-daemon.socket to listen even when root is read-only
  fileSystems."/nix/var/nix/daemon-socket" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "noatime" "mode=0755" "size=1M" ];
  };

  # Volatile NUT state in RAM: allows upsd and upsdrv to write sockets and PID files on read-only root
  fileSystems."/var/lib/nut" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "nosuid" "nodev" "noatime" "mode=0700" "size=2M" ];
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
authentication {
  auth_type PASS
  auth_pass raspberry
}
EOF
              chmod 600 "$TMP_PERSIST/secrets/keepalived-auth.conf"
            fi

            if [ ! -f "$TMP_PERSIST/secrets/nut-monuser-password" ]; then
              echo "changeme" > "$TMP_PERSIST/secrets/nut-monuser-password"
              chmod 600 "$TMP_PERSIST/secrets/nut-monuser-password"
            fi

            if [ ! -f "$TMP_PERSIST/secrets/rclone-pass" ]; then
              echo "changeme" > "$TMP_PERSIST/secrets/rclone-pass"
              chmod 600 "$TMP_PERSIST/secrets/rclone-pass"
            fi

            if [ ! -f "$TMP_PERSIST/secrets/swag.env" ]; then
              cat <<'EOF' > "$TMP_PERSIST/secrets/swag.env"
URL=example.com
EMAIL=admin@example.com
EOF
              chmod 600 "$TMP_PERSIST/secrets/swag.env"
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
        mkdir -p /persist /var/lib/tailscale /var/lib/AdGuardHome /var/lib/docker /nix/var/nix/daemon-socket /var/lib/nut
        ${pkgs.util-linux}/bin/mount -o remount,ro / || true

        ${pkgs.systemd}/bin/udevadm settle || true
      '';
    };
  };

  # 10. Helper command to safely rebuild & upgrade generations.
  #     Automatically remounts / and /boot/firmware read-write,
  #     stops all non-essential services to maximize physical RAM (~700MB+ free),
  #     builds the target generation, and reboots cleanly into the new generation
  #     (or safely restores services and read-only mounts if the build fails).
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "rpi-rebuild" ''
      #!/usr/bin/env bash
      set -euo pipefail

      ACTION="''${1:-boot}"
      FLAKE_TARGET="''${2:-.#}"
      shift 2 2>/dev/null || true

      # If action is 'switch', map to 'boot' since we reboot cleanly after a successful build
      if [ "$ACTION" = "switch" ]; then
        ACTION="boot"
      fi

      echo "==> Remounting / and /boot/firmware as Read-Write..."
      mount -o remount,rw /
      if mountpoint -q /boot/firmware; then
        mount -o remount,rw /boot/firmware || true
      fi

      # Ensure nix-daemon is alive and listening
      systemctl restart nix-daemon.socket nix-daemon.service || true

      # Candidate services to stop to reclaim maximum physical RAM (~700MB+ free)
      CANDIDATE_SERVICES=(
        "docker-swag.service"
        "docker-upswake.service"
        "docker.service"
        "docker.socket"
        "containerd.service"
        "adguardhome.service"
        "glances.service"
        "keepalived.service"
        "upsd.service"
        "upsdrv.service"
      )

      # Only stop tailscaled if no active SSH session is running over Tailscale (100.x)
      if ! ss -tn state established '( sport = :22 )' 2>/dev/null | grep -q ' 100\.'; then
        CANDIDATE_SERVICES+=("tailscaled.service")
      fi

      STOPPED_SERVICES=()
      echo "==> Stopping non-essential services to maximize physical RAM..."
      if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null || true)
        if [ -n "$RUNNING_CONTAINERS" ]; then
          echo "    Stopping active Docker containers..."
          docker stop $RUNNING_CONTAINERS 2>/dev/null || true
        fi
      fi

      for svc in "''${CANDIDATE_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          echo "    Stopping $svc..."
          systemctl stop "$svc" 2>/dev/null || true
          STOPPED_SERVICES+=("$svc")
        fi
      done

      # Drop filesystem caches to free RAM
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
      free -h

      SUCCESS=false
      cleanup() {
        if [ "$SUCCESS" != "true" ]; then
          echo "==> Rebuild failed or was cancelled! Restoring stopped services..."
          for svc in "''${STOPPED_SERVICES[@]}"; do
            echo "    Starting $svc..."
            systemctl start "$svc" 2>/dev/null || true
          done
          echo "==> Restoring partitions to Read-Only..."
          if mountpoint -q /boot/firmware; then
            mount -o remount,ro /boot/firmware || true
          fi
          mount -o remount,ro / || true
        fi
      }
      trap cleanup EXIT INT TERM

      echo "==> Applying NixOS configuration ($ACTION) for $FLAKE_TARGET..."
      nixos-rebuild "$ACTION" --max-jobs 1 --cores 1 --refresh --flake "$FLAKE_TARGET" "$@"

      SUCCESS=true

      if [ "$ACTION" = "boot" ]; then
        echo "==> Rebuild successful! System generation updated."
        echo "==> Syncing disks and restoring Read-Only before reboot..."
        sync
        if mountpoint -q /boot/firmware; then
          mount -o remount,ro /boot/firmware 2>/dev/null || true
        fi
        mount -o remount,ro / 2>/dev/null || true
        echo "==> Rebooting now into the new generation in 3 seconds..."
        sleep 3
        reboot
      else
        echo "==> Action '$ACTION' complete."
        echo "==> Restoring stopped services..."
        for svc in "''${STOPPED_SERVICES[@]}"; do
          echo "    Starting $svc..."
          systemctl start "$svc" 2>/dev/null || true
        done
        echo "==> Restoring partitions to Read-Only..."
        if mountpoint -q /boot/firmware; then
          mount -o remount,ro /boot/firmware || true
        fi
        mount -o remount,ro / || true
      fi
    '')
  ];
}
