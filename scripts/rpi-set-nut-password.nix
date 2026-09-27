{ pkgs }:

pkgs.writeShellScriptBin "rpi-set-nut-password" ''
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run as root (e.g. sudo rpi-set-nut-password)" >&2
    exit 1
  fi
  PASSWORD="''${1:-}"
  if [ -z "$PASSWORD" ]; then
    read -rsp "Enter new NUT monitor password: " PASSWORD
    echo
  fi
  mkdir -p /persist/secrets
  echo -n "$PASSWORD" > /persist/secrets/nut-monuser-password
  chmod 600 /persist/secrets/nut-monuser-password
  echo "==> /persist/secrets/nut-monuser-password updated."
  if command -v rpi-persist-save >/dev/null 2>&1; then
    rpi-persist-save secrets/nut-monuser-password
  fi
  if systemctl list-unit-files | grep -q upsd.service; then
    echo "==> Restarting upsd.service..."
    systemctl restart upsd.service || true
  fi
''
