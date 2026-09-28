{ pkgs }:

pkgs.writeShellScriptBin "rpi-vrrp-status" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Check if the Keepalived Virtual IP (192.168.1.9) is currently assigned locally
  if ${pkgs.iproute2}/bin/ip -brief addr show 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "192.168.1.9"; then
    echo "MASTER (Active on VIP 192.168.1.9)"
  else
    echo "BACKUP (Standby)"
  fi
''
