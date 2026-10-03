{ pkgs }:

pkgs.writeShellScriptBin "rpi-rebuild" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Require root privileges
  if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-rebuild)" >&2
    exit 1
  fi

  # Automatically detect which Pi node we are running on (pi-primary or pi-secondary)
  CURRENT_HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
  DEFAULT_FLAKE="github:willyzha/rpi-nix-configs#$CURRENT_HOST"

  ACTION="boot"
  FLAKE_TARGET=""

  # Flexible argument parsing:
  #   sudo rpi-rebuild                     -> boots github:...#<current-host>
  #   sudo rpi-rebuild test                -> tests github:...#<current-host>
  #   sudo rpi-rebuild switch              -> maps to boot github:...#<current-host>
  #   sudo rpi-rebuild boot .#             -> explicitly specify local flake
  #   sudo rpi-rebuild github:...#target   -> explicitly specify target flake
  if [ $# -ge 1 ]; then
    case "$1" in
      boot|switch|test|build|dry-build|dry-activate)
        ACTION="$1"
        shift
        if [ $# -ge 1 ]; then
          FLAKE_TARGET="$1"
          shift
        fi
        ;;
      *#*|.*|github:*)
        FLAKE_TARGET="$1"
        shift
        ;;
      *)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  FLAKE_TARGET="''${FLAKE_TARGET:-$DEFAULT_FLAKE}"

  # If action is 'switch', map to 'boot' since we reboot cleanly after a successful build
  if [ "$ACTION" = "switch" ]; then
    ACTION="boot"
  fi

  echo "==> Target host: $CURRENT_HOST"
  echo "==> Flake target: $FLAKE_TARGET ($ACTION)"

  # State variables for cleanup trap
  STOPPED_SERVICES=()
  SWAP_ACTIVE=false
  ROOT_REMOUNTED_RW=false
  BOOT_REMOUNTED_RW=false
  SUCCESS=false

  # Detect raw ext4 persistent filesystem (swapfiles cannot reside on an OverlayFS)
  SWAP_DIR="/persist-raw"
  if [ ! -d "$SWAP_DIR" ] || ! mountpoint -q "$SWAP_DIR"; then
    SWAP_DIR="/persist"
  fi
  SWAP_FILE="$SWAP_DIR/.rebuild-swapfile"

  remove_swap() {
    if [ "$SWAP_ACTIVE" = "true" ] || [ -f "$SWAP_FILE" ]; then
      echo "==> Deactivating and removing temporary swap file..."
      swapoff "$SWAP_FILE" 2>/dev/null || true
      rm -f "$SWAP_FILE" 2>/dev/null || true
      SWAP_ACTIVE=false
    fi
  }

  cleanup() {
    local EXIT_CODE=$?
    remove_swap

    if [ "$SUCCESS" != "true" ]; then
      echo ""
      echo "==> [ABORTED] Rebuild failed or was cancelled! Rolling system back to safe state..."
      
      # Restore any stopped services
      if [ ''${#STOPPED_SERVICES[@]} -gt 0 ]; then
        echo "    Restoring stopped services..."
        for svc in "''${STOPPED_SERVICES[@]}"; do
          echo "    Starting $svc..."
          systemctl start "$svc" 2>/dev/null || true
        done
      fi

      # Restore read-only partitions
      echo "    Restoring partitions to Read-Only..."
      if [ "$BOOT_REMOUNTED_RW" = "true" ] && mountpoint -q /boot/firmware; then
        mount -o remount,ro /boot/firmware 2>/dev/null || true
      fi
      if [ "$ROOT_REMOUNTED_RW" = "true" ]; then
        mount -o remount,ro / 2>/dev/null || true
      fi

      echo "==> Rollback complete. System is safe."
    fi
    exit $EXIT_CODE
  }
  trap cleanup EXIT INT TERM

  # Pre-requisite 1: Network Check (if target is remote from github)
  if [[ "$FLAKE_TARGET" =~ ^github: ]]; then
    echo "==> Checking network connectivity before stopping services..."
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
      echo "Error: Network is unreachable! Cannot fetch $FLAKE_TARGET." >&2
      echo "Aborting rebuild before stopping any services." >&2
      exit 1
    fi
  fi

  # Pre-requisite 2: Save any pending overlay changes to SD card before rebuild
  echo "==> Saving any pending /persist overlay changes to SD card before rebuild..."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save || true
  fi

  # Pre-requisite 3: Disk space check on $SWAP_DIR (need at least 2.5GB free for swapfile)
  echo "==> Verifying disk space on $SWAP_DIR for temporary swap..."
  FREE_KB=$(df -k "$SWAP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  if [ "$FREE_KB" -lt 2500000 ]; then
    echo "Error: Insufficient free space on $SWAP_DIR ($((FREE_KB / 1024))MB free; need at least 2500MB)." >&2
    echo "Aborting to prevent disk-full errors." >&2
    exit 1
  fi

  # Pre-requisite 4: Stop heavy services to free maximum physical RAM (~700MB+ free)
  CANDIDATE_SERVICES=(
    "docker-swag.service"
    "docker-upswake.service"
    "docker.service"
    "docker.socket"
    "containerd.service"
    "adguardhome.service"
    "rpi-mqtt-monitor.service"
    "keepalived.service"
    "upsd.service"
    "upsdrv.service"
  )

  # Only stop tailscaled if no active SSH session is running over Tailscale (100.x)
  if ! ss -tn state established '( sport = :22 )' 2>/dev/null | grep -q ' 100\.'; then
    CANDIDATE_SERVICES+=("tailscaled.service")
  fi

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
      STOPPED_SERVICES+=("$svc")
    fi
    echo "    Stopping $svc..."
    systemctl stop "$svc" 2>/dev/null || true
  done

  # Drop filesystem caches to free RAM
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  free -h

  # Pre-requisite 5: Allocate and activate temporary 2GB swap (MANDATORY for 1GB Pi 3B)
  echo "==> Allocating temporary 2GB swap file on $SWAP_DIR to guarantee OOM safety..."
  remove_swap
  if ! fallocate -l 2G "$SWAP_FILE" 2>/dev/null && ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none; then
    echo "Error: Failed to create 2GB swapfile at $SWAP_FILE!" >&2
    echo "Aborting rebuild to prevent out-of-memory kernel freeze." >&2
    exit 1
  fi

  chmod 600 "$SWAP_FILE"
  if ! mkswap "$SWAP_FILE" >/dev/null 2>&1; then
    echo "Error: mkswap failed on $SWAP_FILE!" >&2
    exit 1
  fi

  if ! swapon "$SWAP_FILE" 2>/dev/null; then
    echo "Error: swapon failed for $SWAP_FILE!" >&2
    exit 1
  fi
  SWAP_ACTIVE=true
  echo "    Temporary swap active (secondary to zram):"
  swapon --show 2>/dev/null || true

  # Pre-requisite 6: Remount root as Read-Write and verify writability
  echo "==> Remounting / and /boot/firmware as Read-Write..."
  if ! mount -o remount,rw /; then
    echo "Error: Failed to remount / as Read-Write! Check 'dmesg' for filesystem errors." >&2
    exit 1
  fi
  ROOT_REMOUNTED_RW=true

  # Test that / is actually writable (catches errors=remount-ro locks)
  if ! touch /nix/.rw-test 2>/dev/null; then
    echo "Error: Root filesystem is not writable after remount! Check 'dmesg' for ext4 errors." >&2
    exit 1
  fi
  rm -f /nix/.rw-test 2>/dev/null || true

  if mountpoint -q /boot/firmware; then
    if mount -o remount,rw /boot/firmware 2>/dev/null; then
      BOOT_REMOUNTED_RW=true
    else
      echo "    Notice: /boot/firmware could not be remounted rw (dirty bit or noauto); continuing."
    fi
  fi

  # Ensure nix-daemon socket is active
  if ! systemctl is-active --quiet nix-daemon.socket; then
    systemctl start nix-daemon.socket 2>/dev/null || true
  fi

  echo "==> All pre-requisite checks passed! Starting NixOS build..."
  echo "==> Applying NixOS configuration ($ACTION) for $FLAKE_TARGET..."
  nixos-rebuild "$ACTION" --max-jobs 1 --cores 1 --refresh --flake "$FLAKE_TARGET" "$@"

  SUCCESS=true
  remove_swap
  rm -f /run/rpi-check-update.cache 2>/dev/null || true

  if [ "$ACTION" = "boot" ]; then
    echo "==> Rebuild successful! System generation updated."
    echo "==> Saving any final /persist overlay changes to SD card..."
    if command -v rpi-persist-save >/dev/null 2>&1; then
      rpi-persist-save || true
    fi
    echo "==> Syncing disks and restoring Read-Only before reboot..."
    sync
    if [ "$BOOT_REMOUNTED_RW" = "true" ] && mountpoint -q /boot/firmware; then
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
    if [ "$BOOT_REMOUNTED_RW" = "true" ] && mountpoint -q /boot/firmware; then
      mount -o remount,ro /boot/firmware 2>/dev/null || true
    fi
    mount -o remount,ro / 2>/dev/null || true
  fi
''
