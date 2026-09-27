{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-password" ''
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-password)" >&2
    exit 1
  fi
  TARGET_USER="''${1:-pi}"
  echo "==> Remounting / as Read-Write..."
  mount -o remount,rw /
  cleanup() {
    echo "==> Restoring / as Read-Only..."
    mount -o remount,ro / || true
  }
  trap cleanup EXIT
  echo "==> Setting password for user '$TARGET_USER'..."
  passwd "$TARGET_USER"
  echo "==> Password successfully updated and saved to disk."
''
