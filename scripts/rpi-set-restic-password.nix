{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-restic-password" ''
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-restic-password)" >&2
    exit 1
  fi
  PASSWORD="''${1:-}"
  if [ -z "$PASSWORD" ]; then
    read -rsp "Enter new Restic backup password: " PASSWORD
    echo
  fi
  mkdir -p /persist/secrets
  echo -n "$PASSWORD" > /persist/secrets/restic-password
  chmod 600 /persist/secrets/restic-password
  echo "==> /persist/secrets/restic-password updated."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save secrets/restic-password
  fi
''
