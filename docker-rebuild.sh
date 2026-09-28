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

# Execute rebuild service inside container
exec $COMPOSE_CMD run --rm rebuild "$@"
