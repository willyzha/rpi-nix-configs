{ pkgs }:

pkgs.writeShellScriptBin "rpi-services-status" ''
  #!/usr/bin/env bash
  set -euo pipefail

  HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"
  case "$HOST" in
    kir-pi-primary|pi-primary)
      SERVICES=("keepalived" "adguardhome" "docker" "docker-swag" "rpi-mqtt-monitor" "tailscaled" "upsd")
      ;;
    kir-pi-secondary|pi-secondary)
      SERVICES=("keepalived" "adguardhome" "docker" "docker-swag" "rpi-mqtt-monitor" "tailscaled")
      ;;
    ott-pi-primary|ott-pi|pi-remote)
      SERVICES=("docker" "docker-swag" "rpi-mqtt-monitor" "tailscaled" "mosquitto")
      ;;
    *)
      SERVICES=("docker" "rpi-mqtt-monitor")
      for candidate in keepalived adguardhome tailscaled upsd mosquitto docker-swag; do
        if systemctl is-enabled --quiet "$candidate" 2>/dev/null; then
          SERVICES+=("$candidate")
        fi
      done
      ;;
  esac

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
