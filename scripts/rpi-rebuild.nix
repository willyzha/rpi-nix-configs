{ pkgs }:

pkgs.writeShellScriptBin "rpi-rebuild" ''
  #!/usr/bin/env bash
  set -euo pipefail

  ACTION="''${1:-boot}"
  FLAKE_TARGET="''${2:-.#}"
  shift 2 2>/dev/null || true

  # If action is 'switch', map to 'boot' since we reboot cleanly after a successful build
  if [ "$ACTION" = "switch" ]; then
    ACTION="boot"
  fi

  echo "==> Saving any pending /persist overlay changes to SD card before rebuild..."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save || true
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
    echo "==> Saving any final /persist overlay changes to SD card..."
    if command -v rpi-persist-save >/dev/null 2>&1; then
      rpi-persist-save || true
    fi
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
''
