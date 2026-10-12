#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Helper Script: Host-side Docker Rebuild for Raspberry Pi NixOS
# ==============================================================================

# Verify Docker is available
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker is not installed or not in PATH." >&2
  echo "Please install Docker on your host to use this rebuild tool." >&2
  exit 1
fi

# Detect docker compose plugin vs standalone docker-compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Error: Docker Compose is not installed." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure output directory exists on host for build artifacts / images
mkdir -p "$SCRIPT_DIR/output"

# Host-side DNS / mDNS resolution helper
resolve_host_to_ip() {
  local target="$1"
  if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$target"
    return 0
  fi

  # Fast static mapping for known cluster nodes (prevents mDNS collisions)
  case "$target" in
    kir-pi-primary|pi-primary)
      echo "192.168.1.11"
      return 0
      ;;
    kir-pi-secondary|pi-secondary)
      echo "192.168.1.12"
      return 0
      ;;
    ott-pi-primary|ott-pi|pi-remote)
      echo "100.71.110.64"
      return 0
      ;;
  esac

  local ip=""
  ip=$(getent hosts "$target" 2>/dev/null | awk '{print $1}' | head -n 1)
  if [ -z "$ip" ] && [[ ! "$target" =~ \.local$ ]]; then
    ip=$(getent hosts "${target}.local" 2>/dev/null | awk '{print $1}' | head -n 1)
  fi
  if [ -z "$ip" ] && command -v avahi-resolve >/dev/null 2>&1; then
    local lookup="$target"
    [[ ! "$lookup" =~ \.local$ ]] && lookup="${lookup}.local"
    ip=$(avahi-resolve -n "$lookup" 2>/dev/null | awk '{print $2}' | head -n 1)
  fi
  if [ -z "$ip" ] && command -v python3 >/dev/null 2>&1; then
    local lookup="$target"
    [[ ! "$lookup" =~ \.local$ ]] && lookup="${lookup}.local"
    ip=$(python3 -c "import socket; print(socket.gethostbyname('$lookup'))" 2>/dev/null || true)
  fi
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"
    return 0
  fi
  return 1
}

# Skip remote IP resolution for local actions (build-only, build, image, shell, bash)
IS_LOCAL_ACTION=false
for arg in "$@"; do
  if [[ "$arg" =~ ^(build-only|build|image|shell|bash|test-container)$ ]]; then
    IS_LOCAL_ACTION=true
    break
  fi
done

# Resolve target IP from host DNS/mDNS if a target hostname was provided and not a local-only action
if [ "$IS_LOCAL_ACTION" = "false" ] && [ "$#" -gt 0 ]; then
  # 1. Check if any argument is an explicit IP address
  EXPLICIT_IP=""
  for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      EXPLICIT_IP="$arg"
      break
    fi
  done

  if [ -n "$EXPLICIT_IP" ]; then
    export TARGET_IP="$EXPLICIT_IP"
  else
    FIRST_ARG="$1"
    if [[ ! "$FIRST_ARG" =~ ^(boot|switch|test|dry-build|dry-activate)$ ]]; then
      if RESOLVED_IP=$(resolve_host_to_ip "$FIRST_ARG"); then
        export TARGET_IP="$RESOLVED_IP"
        echo "Host DNS/mDNS resolved '${FIRST_ARG}' -> ${TARGET_IP}"
      elif [[ ! "$FIRST_ARG" =~ ^(help|-h|--help)$ ]]; then
        echo "Error: DNS/mDNS resolution failed for '${FIRST_ARG}'." >&2
        echo "Please specify the IP address directly (e.g. ./docker-rebuild.sh <IP_ADDRESS> [ACTION])." >&2
        exit 1
      fi
    elif [ "$#" -gt 1 ]; then
      SECOND_ARG="$2"
      if RESOLVED_IP=$(resolve_host_to_ip "$SECOND_ARG"); then
        export TARGET_IP="$RESOLVED_IP"
        echo "Host DNS/mDNS resolved '${SECOND_ARG}' -> ${TARGET_IP}"
      else
        echo "Error: DNS/mDNS resolution failed for '${SECOND_ARG}'." >&2
        echo "Please specify the IP address directly (e.g. ./docker-rebuild.sh <IP_ADDRESS> [ACTION])." >&2
        exit 1
      fi
    fi
  fi
fi

# Execute rebuild service inside container
exec $COMPOSE_CMD run --rm rebuild "$@"
