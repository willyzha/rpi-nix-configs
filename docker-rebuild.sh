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

# Sanitize arguments: strip user@ prefix if passed (e.g. pi@kir-pi-primary.local -> kir-pi-primary.local)
CLEANED_ARGS=()
for arg in "$@"; do
  if [[ "$arg" =~ ^([^@]+)@(.+)$ ]]; then
    CLEANED_ARGS+=("${BASH_REMATCH[2]}")
  else
    CLEANED_ARGS+=("$arg")
  fi
done

# Host-side DNS / mDNS resolution helper (resolves .local names via host avahi/nss before entering container)
resolve_host_to_ip() {
  local target="$1"
  if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$target"
    return 0
  fi
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

# Resolve target IP from host DNS/mDNS if a target hostname was provided
if [ "${#CLEANED_ARGS[@]}" -gt 0 ]; then
  FIRST_ARG="${CLEANED_ARGS[0]}"
  if [[ ! "$FIRST_ARG" =~ ^(boot|switch|test|dry-build|dry-activate|build-only|build|image|shell|bash)$ ]]; then
    if RESOLVED_IP=$(resolve_host_to_ip "$FIRST_ARG"); then
      export TARGET_IP="$RESOLVED_IP"
      echo "Host DNS/mDNS resolved '${FIRST_ARG}' -> ${TARGET_IP}"
    fi
  elif [ "${#CLEANED_ARGS[@]}" -gt 1 ]; then
    SECOND_ARG="${CLEANED_ARGS[1]}"
    if RESOLVED_IP=$(resolve_host_to_ip "$SECOND_ARG"); then
      export TARGET_IP="$RESOLVED_IP"
      echo "Host DNS/mDNS resolved '${SECOND_ARG}' -> ${TARGET_IP}"
    fi
  fi
fi

# Execute rebuild service inside container
exec $COMPOSE_CMD run --rm rebuild "${CLEANED_ARGS[@]}"
