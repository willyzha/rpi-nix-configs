{ pkgs }:

pkgs.writeShellScriptBin "rpi-services-status" ''
  #!/usr/bin/env bash
  set -euo pipefail

  HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
  SERVICES=("keepalived" "adguardhome" "docker" "docker-swag" "glances")

  # tailscaled and upsd only run on pi-primary
  if [ "$HOST" = "pi-primary" ]; then
    SERVICES+=("tailscaled" "upsd")
  fi

  FAILED=()
  TOTAL=0
  OK=0

  for svc in "''${SERVICES[@]}"; do
    TOTAL=$((TOTAL + 1))
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      OK=$((OK + 1))
    else
      FAILED+=("$svc")
    fi
  done

  if [ ''${#FAILED[@]} -eq 0 ]; then
    echo "HEALTHY ($OK/$TOTAL active)"
  else
    echo "DEGRADED (failed: ''${FAILED[*]})"
  fi
''
