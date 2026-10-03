{ pkgs }:

pkgs.writeShellScriptBin "rpi-services-status" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Base core services present on all nodes
  SERVICES=("docker" "rpi-mqtt-monitor")

  # Discover all enabled Docker container services (docker-*.service)
  while IFS= read -r svc; do
    [ -n "$svc" ] && SERVICES+=("$svc")
  done < <(systemctl list-unit-files 'docker-*.service' --state=enabled --no-legend 2>/dev/null | awk '{print $1}')

  # Discover enabled native cluster daemons
  CANDIDATES=(
    "keepalived"
    "adguardhome"
    "tailscaled"
    "upsd"
    "mosquitto"
    "espresense-tracker"
    "wireguard-wg0"
    "wg-quick-wg0"
  )

  for candidate in "''${CANDIDATES[@]}"; do
    if systemctl is-enabled --quiet "$candidate" 2>/dev/null; then
      SERVICES+=("$candidate")
    fi
  done

  # Deduplicate and normalize service names (strip .service suffix)
  UNIQUE_SERVICES=()
  declare -A SEEN
  for s in "''${SERVICES[@]}"; do
    s="''${s%.service}"
    if [ -z "''${SEEN[$s]:-}" ]; then
      SEEN["$s"]=1
      UNIQUE_SERVICES+=("$s")
    fi
  done

  FAILED=()
  TOTAL=0
  OK=0

  for svc in "''${UNIQUE_SERVICES[@]}"; do
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
