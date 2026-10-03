{ pkgs }:

pkgs.writeShellScriptBin "rpi-vrrp-status" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Check if Keepalived service is running
  if ! systemctl is-active --quiet keepalived.service 2>/dev/null; then
    echo "DISABLED"
    exit 0
  fi

  # Check if the Keepalived Virtual IP (192.168.1.9) is currently assigned locally
  if ${pkgs.iproute2}/bin/ip -brief addr show 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "192.168.1.9"; then
    echo "MASTER"
  else
    echo "BACKUP"
  fi
''
