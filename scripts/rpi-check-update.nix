{ pkgs }:

pkgs.writeShellScriptBin "rpi-check-update" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # Ensure nix can query metadata in RAM even when root / is read-only
  export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-/tmp/.cache}"

  FLAKE_REF="github:willyzha/rpi-nix-configs"

  echo "==> Querying latest GitHub commit for $FLAKE_REF..."

  # Query latest commit info from GitHub via flake metadata (~1-2 seconds, no heavy NixOS evaluation)
  META=$(${pkgs.nix}/bin/nix flake metadata "$FLAKE_REF" --refresh --json 2>/dev/null || true)

  if [ -z "$META" ]; then
    echo "Error: Failed to fetch metadata from $FLAKE_REF. Check network connectivity." >&2
    exit 2
  fi

  LATEST_REV=$(echo "$META" | ${pkgs.jq}/bin/jq -r '.revision // "unknown"')
  LATEST_TIME=$(echo "$META" | ${pkgs.jq}/bin/jq -r '.lastModified // 0')
  LATEST_DATE=""
  if [ "$LATEST_TIME" -gt 0 ]; then
    LATEST_DATE=$(date -d "@$LATEST_TIME" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")
  fi

  # Read running system's baked-in configuration revision
  CURRENT_REV=""
  if [ -f /run/current-system/configuration-revision ]; then
    CURRENT_REV=$(cat /run/current-system/configuration-revision)
  fi

  echo ""
  if [ -n "$CURRENT_REV" ]; then
    echo "Running System Commit: $CURRENT_REV"
  else
    echo "Running System Commit: (unknown - generation built before commit tracking)"
  fi

  if [ -n "$LATEST_DATE" ]; then
    echo "Latest GitHub Commit:  $LATEST_REV ($LATEST_DATE)"
  else
    echo "Latest GitHub Commit:  $LATEST_REV"
  fi
  echo ""

  if [ -n "$CURRENT_REV" ] && [ "$CURRENT_REV" = "$LATEST_REV" ]; then
    echo "✅ System is up to date with the latest GitHub commit!"
    exit 0
  else
    echo "⚠️ Update available on GitHub!"
    echo "   To apply this update, run:"
    echo "   sudo rpi-rebuild"
    exit 1
  fi
''
